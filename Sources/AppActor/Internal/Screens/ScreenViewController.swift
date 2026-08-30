#if canImport(UIKit) && canImport(WebKit) && !os(watchOS) && !os(tvOS)

import Foundation
import UIKit
import WebKit
#if canImport(SafariServices)
import SafariServices
#endif

/// The WebKit half of a presented screen: a full-screen `WKWebView`, one narrow
/// message handler, and nothing else.
///
/// Every decision this class makes is about *not* being a browser. It ships one
/// page it built itself, refuses every navigation after that one, exposes a
/// single named channel, and hands anything that arrives on it straight to
/// ``AppActorScreenSession``. There is no logic here to get wrong, which is the
/// point: the parts worth testing live in files that compile on a Mac.
///
/// It deliberately does not reuse `AppActorBridge`. That class is a
/// callback wrapper that adapts the async API for hybrid frameworks -- by its
/// own description -- and shares nothing with a WebView bridge but the word.
@MainActor
final class AppActorScreenViewController: UIViewController {

    /// The origin the page is served from.
    ///
    /// Never fetched: `loadSimulatedRequest` hands WebKit the bytes and the
    /// response together. What the URL buys is a real, stable, secure origin --
    /// `loadHTMLString` with a nil base URL produces an *opaque* one, where
    /// `localStorage` throws `SecurityError` on first touch and the page's own
    /// `script-src 'self'` matches nothing.
    private static let origin = "https://screens.appactor.io"
    private static let originHost = "screens.appactor.io"

    private var session: AppActorScreenSession!
    private let lookupKey: String
    private let locale: String
    /// Internal rather than private so the integration tests can drive the
    /// real page: the one thing that cannot be checked without a running
    /// WebKit is whether the runtime boots at all under the shell's CSP.
    private(set) var webView: WKWebView!
    private var handlerProxy: MessageHandlerProxy?
    private var didSendInit = false

    /// Called once, when the screen is finished with. The presenting side turns
    /// this into the value `presentScreen` returns.
    var onFinished: ((AppActorScreenOutcome) -> Void)?

    /// True when the screen closed because it could not render -- the page
    /// failed to load, the runtime never reported ready, or the content process
    /// died. The caller turns this into a thrown error so the host app can fall
    /// back to its own paywall instead of treating it as a dismissal.
    private(set) var failedToRender = false

    init(
        document: AppActorScreenDocument,
        packages: [[String: Any]],
        gateway: AppActorScreenPurchaseGateway,
        locale: String,
        onEvent: ((AppActorScreenEvent) -> Void)?
    ) {
        self.lookupKey = document.lookupKey
        self.locale = locale
        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve

        // The session needs a host and the host needs a session; building it
        // here rather than passing one in is what keeps that knot out of the
        // caller.
        let session = AppActorScreenSession(
            host: self,
            gateway: gateway,
            document: document,
            packages: packages,
            onEvent: onEvent
        )
        session.onReadyTimeout = { [weak self] in
            self?.failedToRender = true
            self?.finish(.dismissed)
        }
        self.session = session
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        // `WKUserContentController` retains its message handlers strongly, so
        // the proxy exists to break that cycle -- and it still has to be
        // removed, or the controller keeps a live channel into a dead screen.
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: AppActorScreenProtocol.webChannel)
    }

    // MARK: - View

    override func loadView() {
        let configuration = WKWebViewConfiguration()

        // Ephemeral: a paywall has nothing worth persisting, and a shared
        // persistent store would leave cookies and local storage behind in the
        // host app's data directory.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = false

        let proxy = MessageHandlerProxy(target: self)
        handlerProxy = proxy
        configuration.userContentController.add(proxy, name: AppActorScreenProtocol.webChannel)

        // The runtime goes in as a user script rather than a `<script>` tag.
        // User scripts are injected by the engine before the page's own content
        // security policy applies, so the shell keeps `script-src 'self'` --
        // the rule that stops a hole in the runtime from becoming arbitrary
        // code execution -- while still having no external subresource to fetch.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: AppActorScreenRuntimeAsset.runtimeJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false

        // Hidden until the runtime reports `ready`. The view controller is
        // presented immediately anyway, because a WKWebView outside a window
        // never gets a `requestAnimationFrame` callback -- so presenting late
        // would mean `paintConfirmed: false` on every single screen, and the
        // signal would stop meaning anything.
        webView.alpha = 0

        self.webView = webView

        let container = UIView()
        container.backgroundColor = .clear
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let url = URL(string: "\(Self.origin)/\(lookupKey)"),
              let html = AppActorScreenRuntimeAsset.shellHTML.data(using: .utf8),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/html; charset=utf-8"]
              )
        else {
            Log.screens.error("Screen \(lookupKey): could not build the page shell")
            failedToRender = true
            finish(.dismissed)
            return
        }

        webView.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: html)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The host app can take the screen down without the runtime asking:
        // `dismiss` from a deep-link handler, a replaced `rootViewController`.
        // Without this the continuation in `presentScreen` is never resumed --
        // that call stays suspended for the life of the process, and the
        // one-screen-at-a-time flag it set on the way in is never cleared, so
        // every later `presentScreen` refuses.
        guard !didFinish, view.window == nil else { return }
        Log.screens.debug("Screen \(lookupKey) was dismissed by the host app")
        finish(.dismissed)
    }

    // MARK: - Finishing

    private var didFinish = false

    fileprivate func finish(_ outcome: AppActorScreenOutcome) {
        guard !didFinish else { return }
        didFinish = true

        session.cancel()
        // Let the runtime emit `dismiss{source:"native"}` before the page dies.
        // A no-op when the page never loaded, which is exactly the case where
        // there is no event to lose.
        session.notifyDismissed()

        let complete = { [weak self] in
            guard let self else { return }
            self.onFinished?(outcome)
            self.onFinished = nil
        }

        // `didFinish` is already set, so nothing else will deliver this
        // outcome -- the completion has to run whether or not UIKit calls it.
        if presentingViewController != nil, view.window != nil {
            dismiss(animated: true, completion: complete)
        } else {
            complete()
        }
    }
}

// MARK: - Session host

extension AppActorScreenViewController: AppActorScreenHost {

    func send(_ messages: [AppActorScreenInbound]) {
        guard let source = AppActorScreenInboundBatch.javaScript(for: messages) else {
            Log.screens.error("Screen \(lookupKey): nothing in the batch could be encoded")
            return
        }
        webView.evaluateJavaScript(source) { _, error in
            // An error here means the runtime is not there to receive it --
            // the page never loaded, or it was torn down mid-flight. Nothing to
            // retry against, so this is a log and not a recovery path.
            if let error {
                Log.screens.warn("Screen delivery failed: \(error.localizedDescription)")
            }
        }
    }

    func screenBecameReady(paintConfirmed: Bool) {
        let reveal = { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) { self.webView.alpha = 1 }
        }
        if paintConfirmed {
            reveal()
        } else {
            // rAF never fired, so `ready` came from the runtime's safety net and
            // the first frame may not exist. One turn of the run loop is enough
            // to avoid revealing an empty page.
            DispatchQueue.main.async(execute: reveal)
        }
    }

    func closeScreen(_ outcome: AppActorScreenOutcome) {
        finish(outcome)
    }

    func openExternal(url: URL, method: String) {
        #if canImport(SafariServices)
        if method == "in_app_browser" {
            let safari = SFSafariViewController(url: url)
            safari.modalPresentationStyle = .formSheet
            present(safari, animated: true)
            return
        }
        #endif
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - Message channel

extension AppActorScreenViewController {

    fileprivate func receive(_ body: Any) {
        switch AppActorScreenOutbound.decode(body) {
        case .success(let message):
            session.handle(message)
        case .failure(let failure):
            // Dropping one message never affects another: on iOS each
            // `postMessage` is its own delegate callback, so there is no batch
            // here to poison. The direction that does batch is native → web,
            // and the runtime decodes those one at a time for the same reason.
            Log.screens.warn("Screen \(lookupKey) dropped a message: \(failure.reason)")
        }
    }

    /// Breaks the retain cycle `WKUserContentController` would otherwise create
    /// by holding its message handlers strongly.
    private final class MessageHandlerProxy: NSObject, WKScriptMessageHandler {
        private weak var target: AppActorScreenViewController?

        init(target: AppActorScreenViewController) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.name == AppActorScreenProtocol.webChannel else { return }
                target?.receive(message.body)
            }
        }
    }
}

// MARK: - Navigation

extension AppActorScreenViewController: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didSendInit else { return }
        didSendInit = true
        session.sendInit(locale: locale, assetBase: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.screens.error("Screen \(lookupKey) failed to load: \(error.localizedDescription)")
        failedToRender = true
        finish(.dismissed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.screens.error("Screen \(lookupKey) failed to load: \(error.localizedDescription)")
        failedToRender = true
        finish(.dismissed)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Exactly one navigation is allowed: the one this class started. Links
        // go through the `openUrl` action, which is policed on both sides and
        // opens outside the screen. The page's CSP already blocks most of this;
        // this is the half that does not depend on the page behaving.
        //
        // Compared on the parsed host, never on the string. A prefix test lets
        // `https://screens.appactor.io@evil.example/` through -- everything
        // before the `@` is userinfo, and the host is `evil.example` -- and
        // `https://screens.appactor.io.evil.example/` with it. Either one puts
        // an attacker-controlled origin inside the paywall's web view, holding
        // a live bridge that can post `purchase` and read every reply.
        let url = navigationAction.request.url
        let isOwnOrigin = url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == Self.originHost
        let isInitialLoad = navigationAction.navigationType == .other
            && navigationAction.targetFrame?.isMainFrame == true
            && isOwnOrigin

        if isInitialLoad {
            decisionHandler(.allow)
        } else {
            Log.screens.warn("Screen \(lookupKey) blocked a navigation to \(navigationAction.request.url?.absoluteString ?? "?")")
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `window.open` and `target="_blank"`: never a second web view.
        nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Jetsam. Reloading would restart a flow the user may be midway
        // through, with a purchase possibly in flight; handing control back to
        // the host app is the honest outcome.
        Log.screens.error("Screen \(lookupKey): web content process terminated")
        failedToRender = true
        finish(.dismissed)
    }
}

// MARK: - Presentation

enum AppActorScreenPresenter {

    /// The view controller a modal should be presented from.
    ///
    /// Walks from the foreground-active scene's key window down through
    /// whatever is already presented, so a screen shown from inside another
    /// modal lands on top of it instead of throwing
    /// "presenting a view controller that is already presenting".
    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first else {
            return nil
        }

        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

#endif
