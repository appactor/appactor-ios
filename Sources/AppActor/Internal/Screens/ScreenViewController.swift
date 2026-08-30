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
/// Every decision here is about *not* being a browser -- one self-built page,
/// no navigation after it, a single named channel handed straight to
/// ``AppActorScreenSession``. The logic worth testing lives in files that
/// compile on a Mac.
///
/// Not `AppActorBridge`: that is a callback wrapper for hybrid frameworks and
/// shares nothing with a WebView bridge but the word.
@MainActor
final class AppActorScreenViewController: UIViewController {

    /// Never fetched -- `loadSimulatedRequest` supplies the bytes. The URL buys
    /// a real, stable, secure origin; `loadHTMLString` with a nil base URL
    /// gives an *opaque* one, where `localStorage` throws and the page's own
    /// `script-src 'self'` matches nothing.
    private static let origin = "https://screens.appactor.com"
    private static let originHost = "screens.appactor.com"

    /// Built once for the process, not per presentation: ~33 KB to copy into a
    /// `WKUserScript` and ~3 KB to transcode, all of it on the path to first
    /// paint.
    private static let runtimeUserScript = WKUserScript(
        // A user script, not a `<script>` tag: the engine injects it before the
        // page's CSP applies, so the shell keeps `script-src 'self'` with no
        // external subresource to fetch.
        source: AppActorScreenRuntimeAsset.runtimeJS,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
    private static let shellData = Data(AppActorScreenRuntimeAsset.shellHTML.utf8)

    private var session: AppActorScreenSession!
    private let lookupKey: String
    private let locale: String
    /// Internal rather than private so the integration tests can drive the
    /// real page: the one thing that cannot be checked without a running
    /// WebKit is whether the runtime boots at all under the shell's CSP.
    private(set) var webView: WKWebView!
    private var didSendInit = false

    /// The exact request handed to `loadSimulatedRequest`, and whether WebKit
    /// has been allowed to perform it. Together they are what makes
    /// "exactly one navigation" true rather than merely intended.
    private var pageURL: URL?
    private var didAllowInitialNavigation = false

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
            self?.failToRender("the runtime never reported ready")
        }
        self.session = session
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // No `deinit` teardown on purpose: the deinit of a `@MainActor` class is
    // not guaranteed to run on the main thread, and `removeScriptMessageHandler`
    // off-main is a WebKit assertion. `finish` is main-actor by construction and
    // every path off this screen goes through it, so the teardown lives there.

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

        // Not stored: `add(_:name:)` retains the proxy strongly, which is
        // exactly why `deinit` has to remove it again.
        configuration.userContentController.add(MessageHandlerProxy(target: self), name: AppActorScreenProtocol.webChannel)

        configuration.userContentController.addUserScript(Self.runtimeUserScript)

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

        // Hidden until `ready`, but presented immediately: a WKWebView outside
        // a window never gets `requestAnimationFrame`, so presenting late would
        // mean `paintConfirmed: false` on every screen.
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
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/html; charset=utf-8"]
              )
        else {
            failToRender("could not build the page shell")
            return
        }

        pageURL = url
        webView.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: Self.shellData)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The host app can take the screen down without the runtime asking.
        // Without this the `presentScreen` continuation is never resumed and
        // the one-screen-at-a-time flag is never cleared.
        guard !didFinish, view.window == nil else { return }
        Log.screens.debug("Screen \(lookupKey) was dismissed by the host app")
        finish(.dismissed)
    }

    // MARK: - Finishing

    private var didFinish = false

    /// The screen could not be shown. Four call sites reach this and they must
    /// agree: `failedToRender` decides whether the host app gets a thrown error
    /// it can fall back from, or a dismissal it reads as "the user said no".
    func failToRender(_ reason: String) {
        Log.screens.error("Screen \(lookupKey): \(reason)")
        failedToRender = true
        finish(.dismissed)
    }

    fileprivate func finish(_ outcome: AppActorScreenOutcome) {
        guard !didFinish else { return }
        didFinish = true

        session.cancel()

        // Close the channel here, on the main actor, rather than in `deinit`
        // where the thread is not ours to choose.
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: AppActorScreenProtocol.webChannel)

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
        failToRender("failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failToRender("failed to load: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Exactly one navigation is allowed, and that has to be *checked*:
        // matching only shape and host would let every later main-frame
        // navigation to that host through, and those are fetched from the real
        // network. A page reaching `location.href` would swap the shell for
        // whatever the host served while the message handler and the injected
        // runtime stayed live -- a replacement document holding a bridge that
        // can post `purchase`. So the URL must equal the one handed to
        // `loadSimulatedRequest`, once.
        //
        // The host is compared parsed, never as a string: a prefix test lets
        // `https://host@evil.example/` through, where the real host is
        // `evil.example`.
        let url = navigationAction.request.url
        let isOwnOrigin = url?.scheme?.lowercased() == "https"
            && url?.host?.lowercased() == Self.originHost
        let isInitialLoad = !didAllowInitialNavigation
            && url == pageURL
            && navigationAction.navigationType == .other
            && navigationAction.targetFrame?.isMainFrame == true
            && isOwnOrigin

        if isInitialLoad {
            didAllowInitialNavigation = true
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
        failToRender("web content process terminated")
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
