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
    #if canImport(UIKit) && !os(watchOS)
    /// Replaced in tests.
    static var isAvailable: () -> Bool = {
        // Before the probe has been written, only isProtectedDataAvailable can tell, and it
        // is also false on a device that is merely locked again.
        firstUnlockProbeIsReadable() ?? UIApplication.shared.isProtectedDataAvailable
    }

    /// A small file with the same protection class as UserDefaults. Apple documents that a
    /// `completeUntilFirstUserAuthentication` file can't be accessed until the user unlocks the
    /// device for the first time after boot, and stays accessible while it is locked again.
    static var probeURL: URL {
        AppActorAtomicJSONQueueStore.defaultDirectory.appendingPathComponent("first-unlock-probe")
    }

    /// Writes the probe file if it is missing. Called once the stored identity is known to be
    /// readable, so the probe is in place before the next launch that comes before the first
    /// unlock after a reboot.
    static func recordFirstUnlockProbe() {
        guard !FileManager.default.fileExists(atPath: probeURL.path) else { return }
        try? FileManager.default.createDirectory(
            at: probeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data([1]).write(to: probeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Returns once protected data is available, right away if it already is.
    static func waitUntilAvailable() async {
        guard !isAvailable() else { return }
        Log.sdk.warn("Device not unlocked since boot; waiting for the first unlock before reading the stored identity")
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.start(continuation)
            }
        } onCancel: {
            Task { @MainActor in waiter.finish() }
        }
    }

    /// Whether the probe can be read, or nil when it hasn't been written yet.
    private static func firstUnlockProbeIsReadable() -> Bool? {
        guard FileManager.default.fileExists(atPath: probeURL.path) else { return nil }
        return (try? Data(contentsOf: probeURL)) != nil
    }

    /// Resumes once, on the first of: protected data becoming available, or cancellation.
    @MainActor
    private final class Waiter {
        private var continuation: CheckedContinuation<Void, Never>?
        private var observer: NSObjectProtocol?

        func start(_ continuation: CheckedContinuation<Void, Never>) {
            // Cancelled already, or unlocked between the first check and now.
            guard !Task.isCancelled, !isAvailable() else {
                continuation.resume()
                return
            }
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
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
    #else
    /// Replaced in tests. Data protection doesn't hold back reads on this platform.
    static var isAvailable: () -> Bool = { true }

    static func recordFirstUnlockProbe() {}

    static func waitUntilAvailable() async {}
    #endif
}
