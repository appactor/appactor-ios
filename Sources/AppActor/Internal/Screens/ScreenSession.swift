import Foundation

/// Everything the screen needs from the world around it, behind two protocols.
///
/// This is what lets the whole bridge be tested on the macOS host: the session
/// owns the protocol, the request matching, the purchase state machine and the
/// watchdog, and none of that needs a `WKWebView` or a `UIViewController` to
/// exercise. The WebKit layer implements ``AppActorScreenHost`` and does
/// nothing but move bytes.
@MainActor
protocol AppActorScreenHost: AnyObject {
    /// Delivers a batch to the runtime. Always a batch, never a single message.
    func send(_ messages: [AppActorScreenInbound])
    /// The runtime asked to close, or the session gave up on it.
    func closeScreen(_ outcome: AppActorScreenOutcome)
    /// The screen painted. Until this fires the view stays off-screen.
    func screenBecameReady(paintConfirmed: Bool)
    func openExternal(url: URL, method: String)
}

@MainActor
protocol AppActorScreenPurchaseGateway: AnyObject {
    func purchase(packageId: String) async -> AppActorScreenPurchaseOutcome
    func restore() async -> AppActorScreenRestoreOutcome
    /// Waits for a queued receipt to reach a terminal state, or gives up.
    func awaitServerConfirmation(transactionId: String) async -> AppActorScreenConfirmation
}

enum AppActorScreenPurchaseOutcome {
    /// `transactionId` is `nil` when the purchase completed without one to
    /// follow up on; there is then nothing to confirm later.
    case completed(serverConfirmed: Bool, transactionId: String?)
    case cancelled
    case pending
    case failed(String)
}

enum AppActorScreenRestoreOutcome {
    case restored
    case nothingToRestore
    case cancelled
    case failed(String)
}

enum AppActorScreenConfirmation {
    case confirmed
    case failed(String)
    /// Still queued when we stopped waiting. Nothing is claimed either way —
    /// saying "failed" here would be a lie about a receipt that may well post
    /// ten seconds later.
    case unknown
}

/// How a screen ended. Returned from `presentScreen`.
public enum AppActorScreenOutcome: Sendable, Equatable {
    /// A purchase completed and the server confirmed it.
    case purchased
    /// A restore found something to restore.
    case restored
    /// The user closed the screen, or the host app dismissed it.
    case dismissed
}

/// One analytics event from a screen.
///
/// The names are a closed, frozen list (`FROZEN.md` §1) because
/// `purchase_completed` is tied to historical revenue attribution. Adding a
/// name is allowed; renaming one is not.
public struct AppActorScreenEvent {
    /// e.g. `impression`, `screen_view`, `cta_tap`, `purchase_completed`.
    public let name: String
    /// The screen the event came from.
    public let lookupKey: String
    public let properties: [String: Any]
}

/// Routes bridge traffic for one presented screen.
///
/// Owns the request/response matching for purchase and restore. The runtime
/// refuses any result it cannot match to an in-flight request by `requestId`
/// (day-1 rule #14) and answers with `unmatched_purchase_result`, so every
/// reply this file sends carries back the id it was asked with.
@MainActor
final class AppActorScreenSession {

    private weak var host: AppActorScreenHost?
    private let gateway: AppActorScreenPurchaseGateway
    private let document: AppActorScreenDocument
    private let packages: [[String: Any]]
    private let onEvent: ((AppActorScreenEvent) -> Void)?

    private var didBecomeReady = false
    private var watchdog: Task<Void, Never>?
    private var work: [Task<Void, Never>] = []
    private(set) var outcome: AppActorScreenOutcome = .dismissed

    /// Fires when the runtime never reports `ready`. Distinct from the
    /// runtime's own 2s `slow_first_paint`: that one assumes the runtime is
    /// alive to report it, and the case this covers is the one where it is not.
    var onReadyTimeout: (() -> Void)?

    init(
        host: AppActorScreenHost,
        gateway: AppActorScreenPurchaseGateway,
        document: AppActorScreenDocument,
        packages: [[String: Any]],
        onEvent: ((AppActorScreenEvent) -> Void)?
    ) {
        self.host = host
        self.gateway = gateway
        self.document = document
        self.packages = packages
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    /// The first thing the runtime hears. Sent once the page has loaded.
    func sendInit(locale: String, assetBase: String?) {
        var payload: [String: Any] = ["document": document.json]
        if !packages.isEmpty { payload["packages"] = packages }

        var context: [String: Any] = ["locale": locale]
        if let assetBase { context["assetBase"] = assetBase }
        payload["context"] = context

        host?.send([AppActorScreenInbound(.initialise, payload: payload)])
        startReadyWatchdog()
    }

    private func startReadyWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppActorScreenProtocol.readyWatchdog * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.didBecomeReady else { return }
            Log.screens.error("Screen \(self.document.lookupKey) never reported ready — falling back")
            self.onReadyTimeout?()
        }
    }

    /// Cancels the watchdog and every in-flight reply.
    ///
    /// Called when the screen goes away. A purchase that resolves after this
    /// point must not post into a dead web view, and — more importantly — must
    /// not deliver a result the user can no longer see.
    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        for task in work { task.cancel() }
        work.removeAll()
    }

    /// Tells the runtime the screen is being dismissed from the native side,
    /// so it emits `dismiss{source:"native"}` rather than losing the event.
    func notifyDismissed() {
        host?.send([AppActorScreenInbound(.dismiss)])
    }

    // MARK: - Routing

    func handle(_ message: AppActorScreenOutbound) {
        switch message.type {
        case .ready:
            handleReady(message)
        case .purchase:
            handlePurchase(message)
        case .restore:
            handleRestore(message)
        case .close:
            host?.closeScreen(outcome)
        case .navigate:
            // v1 presents one screen at a time; there is no stack to push onto.
            // The runtime does not wait for a reply, so logging is the whole
            // of the correct behaviour here.
            Log.screens.warn("Screen \(document.lookupKey) requested navigation to \(message.string("to") ?? "?"); not supported in this version")
        case .openUrl:
            handleOpenUrl(message)
        case .event:
            handleEvent(message)
        case .error:
            let code = message.string("code").map { " [\($0)]" } ?? ""
            Log.screens.error("Screen \(document.lookupKey)\(code): \(message.string("message") ?? "unknown error")")
        }
    }

    private func handleReady(_ message: AppActorScreenOutbound) {
        guard !didBecomeReady else { return }
        didBecomeReady = true
        watchdog?.cancel()
        watchdog = nil

        // `paintConfirmed: false` means rAF never fired — the WebView was
        // throttled, so `ready` came from the runtime's own safety net and the
        // first frame may not exist yet. The host waits one turn before
        // revealing rather than flashing an empty screen.
        let painted = message.payload["paintConfirmed"] as? Bool ?? false
        Log.screens.debug("Screen \(document.lookupKey) ready (runtime \(message.string("runtimeVersion") ?? "?"), painted: \(painted))")
        host?.screenBecameReady(paintConfirmed: painted)
    }

    /// Schemes refused in every mode, mirroring `FORBIDDEN_DEEP_LINK_SCHEMES`
    /// in `spec/open-url.ts`: the ones that turn a document into code or reach
    /// the file system, plus the web schemes, which belong to the browser modes.
    private static let forbiddenDeepLinkSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "about", "filesystem",
        "http", "https", "ws", "wss",
    ]

    /// `URL_REJECT_CHARS_RE` in `spec/open-url.ts`.
    private static let rejectedURLCharacters = CharacterSet(charactersIn: "\\")
        .union(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x20)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(0x7f)...Unicode.Scalar(0x7f)))

    private func handleOpenUrl(_ message: AppActorScreenOutbound) {
        guard let raw = message.string("url"), let method = message.string("method") else {
            Log.screens.warn("Screen \(document.lookupKey) sent an unusable openUrl")
            return
        }

        // The runtime applies this policy too, but it applies it inside the
        // page. This copy is the one a compromised document cannot reach, so
        // it has to be at least as strict -- not merely similar.
        guard raw.count <= 2048, raw.rangeOfCharacter(from: Self.rejectedURLCharacters) == nil else {
            Log.screens.warn("Screen \(document.lookupKey) sent an openUrl with an unusable URL")
            return
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            Log.screens.warn("Screen \(document.lookupKey) sent an unparseable openUrl")
            return
        }

        switch method {
        case "in_app_browser", "external_browser":
            let allowed = method == "in_app_browser" ? ["https"] : ["https", "http"]
            guard allowed.contains(scheme) else {
                Log.screens.warn("Screen \(document.lookupKey) asked to open \(scheme) via \(method)")
                return
            }
            // `https://apple.com@evil.example/` reads as Apple's domain and
            // loads someone else's. The shared policy refuses credentials in a
            // web URL for that reason; so does this.
            guard url.user == nil, url.password == nil, url.host?.isEmpty == false else {
                Log.screens.warn("Screen \(document.lookupKey) sent a web URL with credentials or no host")
                return
            }
        case "deep_link":
            guard !Self.forbiddenDeepLinkSchemes.contains(scheme) else {
                Log.screens.warn("Screen \(document.lookupKey) asked to deep link to \(scheme)")
                return
            }
            // `<scheme>://<rest>`, as the shared policy requires. Without it
            // `tel:`, `sms:` and `mailto:` become reachable from a document.
            guard raw.lowercased().hasPrefix("\(scheme)://") else {
                Log.screens.warn("Screen \(document.lookupKey) sent a deep link that is not <scheme>://")
                return
            }
        default:
            Log.screens.warn("Screen \(document.lookupKey) sent an unknown openUrl method \"\(method)\"")
            return
        }
        host?.openExternal(url: url, method: method)
    }

    private func handleEvent(_ message: AppActorScreenOutbound) {
        guard let name = message.string("name") else { return }
        let properties = message.payload["props"] as? [String: Any] ?? [:]
        Log.screens.debug("Screen \(document.lookupKey) event: \(name)")
        onEvent?(AppActorScreenEvent(name: name, lookupKey: document.lookupKey, properties: properties))
    }

    // MARK: - Purchase

    private func handlePurchase(_ message: AppActorScreenOutbound) {
        // Rule #14. Without an id the runtime cannot match the reply, and
        // replying anyway would produce an `unmatched_purchase_result` that
        // looks like a bug in the runtime rather than in the sender.
        guard let requestId = message.requestId else {
            Log.screens.error("Screen \(document.lookupKey) sent a purchase with no requestId; ignoring")
            return
        }
        guard let packageId = message.string("packageId"), !packageId.isEmpty else {
            reply(.purchaseResult, requestId, ["status": "failed", "message": "No package was selected."])
            return
        }

        track { [weak self] in
            guard let self else { return }
            let result = await self.gateway.purchase(packageId: packageId)
            guard !Task.isCancelled else { return }

            switch result {
            case .completed(let serverConfirmed, let transactionId):
                self.reply(.purchaseResult, requestId, [
                    "status": "completed",
                    "server_confirmed": serverConfirmed,
                ])
                if serverConfirmed {
                    self.outcome = .purchased
                } else if let transactionId {
                    // Rule #13's second half. The runtime is now in
                    // `confirming`: controls locked, waiting for a second
                    // result under the *same* requestId. Nobody else will
                    // send it.
                    self.followUp(requestId: requestId, transactionId: transactionId)
                }
            case .cancelled:
                self.reply(.purchaseResult, requestId, ["status": "cancelled"])
            case .pending:
                self.reply(.purchaseResult, requestId, ["status": "pending"])
            case .failed(let message):
                self.reply(.purchaseResult, requestId, ["status": "failed", "message": message])
            }
        }
    }

    /// Second result for a purchase that completed without server confirmation.
    private func followUp(requestId: String, transactionId: String) {
        track { [weak self] in
            guard let self else { return }
            let confirmation = await self.gateway.awaitServerConfirmation(transactionId: transactionId)
            guard !Task.isCancelled else { return }

            switch confirmation {
            case .confirmed:
                self.outcome = .purchased
                self.reply(.purchaseResult, requestId, ["status": "completed", "server_confirmed": true])
            case .failed(let message):
                self.reply(.purchaseResult, requestId, ["status": "failed", "message": message])
            case .unknown:
                // Say nothing. The runtime holds `confirming` on its own timer
                // and releases the controls when it expires; inventing a
                // verdict about a receipt still queued for retry would be
                // worse than letting that happen.
                Log.screens.warn("Screen \(self.document.lookupKey): receipt \(transactionId) still unconfirmed; leaving the runtime to time out")
            }
        }
    }

    // MARK: - Restore

    private func handleRestore(_ message: AppActorScreenOutbound) {
        guard let requestId = message.requestId else {
            Log.screens.error("Screen \(document.lookupKey) sent a restore with no requestId; ignoring")
            return
        }

        track { [weak self] in
            guard let self else { return }
            let result = await self.gateway.restore()
            guard !Task.isCancelled else { return }

            switch result {
            case .restored:
                self.outcome = .restored
                self.reply(.restoreResult, requestId, ["status": "restored"])
            case .nothingToRestore:
                self.reply(.restoreResult, requestId, ["status": "nothing_to_restore"])
            case .cancelled:
                self.reply(.restoreResult, requestId, ["status": "cancelled"])
            case .failed(let message):
                self.reply(.restoreResult, requestId, ["status": "failed", "message": message])
            }
        }
    }

    // MARK: - Plumbing

    private func reply(_ type: AppActorScreenInboundType, _ requestId: String, _ payload: [String: Any]) {
        host?.send([AppActorScreenInbound(type, requestId: requestId, payload: payload)])
    }

    /// Keeps a handle on background work so `cancel()` can reach it, and drops
    /// the handle when it finishes so a long-lived screen does not accumulate
    /// one per tap.
    private func track(_ operation: @escaping () async -> Void) {
        // The task has to be able to drop its own handle when it finishes, and
        // it cannot capture a variable it is itself being assigned to. A box
        // gives the closure a stable thing to read once the assignment has
        // happened, which is always after the closure's first suspension.
        let box = TaskBox()
        let task = Task { [weak self] in
            await operation()
            guard let self, let handle = box.task else { return }
            self.work.removeAll { $0 == handle }
        }
        box.task = task
        work.append(task)
    }

    private final class TaskBox {
        var task: Task<Void, Never>?
    }
}
