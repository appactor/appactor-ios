import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Whether data protected until first user authentication can be read yet.
///
/// Until the first unlock after a reboot, iOS can't read the UserDefaults backing store
/// (Apple DTS: it is protected until first user authentication), so every stored key reads
/// as missing. A missing app user ID then means "can't read it yet", not "new install", and
/// minting an anonymous ID would run the session under a phantom identity. Once the device
/// has been unlocked, the data stays readable while it is locked again.
@MainActor
enum AppActorProtectedData {
    /// Replaced in tests.
    static var isAvailable: () -> Bool = {
        #if canImport(UIKit) && !os(watchOS)
        // The probe goes first so it gets written while the data is readable.
        firstUnlockProbeIsReadable() || UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Reads a small file with the same protection class as UserDefaults. Apple documents that
    /// a `completeUntilFirstUserAuthentication` file can't be accessed until the user unlocks
    /// the device for the first time after boot, and stays accessible while it is locked again.
    /// `isProtectedDataAvailable` alone is false whenever the device is locked.
    private static func firstUnlockProbeIsReadable() -> Bool {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("appactor", isDirectory: true) else { return true }
        let probe = directory.appendingPathComponent("first-unlock-probe")
        if FileManager.default.fileExists(atPath: probe.path) {
            return (try? Data(contentsOf: probe)) != nil
        }
        // Not written yet. If it can't be written either, this can't tell, so it doesn't
        // hold anything back.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data([1]).write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
    #endif

    /// Returns once protected data is available, right away if it already is.
    static func waitUntilAvailable() async {
        guard !isAvailable() else { return }
        #if canImport(UIKit) && !os(watchOS)
        Log.sdk.warn("Device not unlocked since boot; waiting for the first unlock before reading the stored identity")
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
