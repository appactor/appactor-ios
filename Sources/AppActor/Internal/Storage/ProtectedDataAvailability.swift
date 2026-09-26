import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Whether the app's protected data can be read yet.
///
/// Until the first unlock after a reboot, iOS can't read the UserDefaults backing store
/// (Apple DTS: it is protected until first user authentication), so every stored key reads
/// as missing. A missing app user ID then means "can't read it yet", not "new install", and
/// minting an anonymous ID would run the session under a phantom identity.
@MainActor
enum AppActorProtectedData {
    /// Replaced in tests.
    static var isAvailable: () -> Bool = {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// Returns once protected data is available, right away if it already is.
    static func waitUntilAvailable() async {
        guard !isAvailable() else { return }
        #if canImport(UIKit) && !os(watchOS)
        Log.sdk.warn("Protected data is unavailable (device not unlocked since boot); waiting for it before reading the stored identity")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = Waiter(continuation)
            waiter.observer = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { waiter.finish() }
            }
            // The device may have been unlocked between the first check and the observer.
            if isAvailable() {
                waiter.finish()
            }
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private final class Waiter {
        private var continuation: CheckedContinuation<Void, Never>?
        var observer: NSObjectProtocol?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            continuation?.resume()
            continuation = nil
        }
    }
    #endif
}
