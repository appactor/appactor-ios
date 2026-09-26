import XCTest
@testable import AppActor
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

@MainActor
final class ProtectedDataTests: XCTestCase {

    func testWaitReturnsRightAwayWhenAvailable() async {
        let isAvailable = AppActorProtectedData.isAvailable
        defer { AppActorProtectedData.isAvailable = isAvailable }
        AppActorProtectedData.isAvailable = { true }

        await AppActorProtectedData.waitUntilAvailable()
    }

    #if canImport(UIKit) && !os(watchOS)
    func testRecordedProbeReadsBackAsAvailable() {
        let probe = AppActorProtectedData.probeURL
        defer { try? FileManager.default.removeItem(at: probe) }
        AppActorProtectedData.recordFirstUnlockProbe()

        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path))
        XCTAssertTrue(AppActorProtectedData.isAvailable())
    }

    func testWaitResumesWhenProtectedDataBecomesAvailable() async {
        let isAvailable = AppActorProtectedData.isAvailable
        defer { AppActorProtectedData.isAvailable = isAvailable }
        var available = false
        AppActorProtectedData.isAvailable = { available }

        var finished = false
        let wait = Task { @MainActor in
            await AppActorProtectedData.waitUntilAvailable()
            finished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)

        available = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await wait.value

        XCTAssertTrue(finished)
    }
    #endif
}
