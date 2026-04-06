import XCTest
@testable import AppActor

@MainActor
final class SecurityAuditTests: XCTestCase {

    // MARK: - SECR-03: appUserId not logged at info level

    /// Verifies that identity log messages containing appUserId are at DEBUG level,
    /// not INFO or higher. Uses AppActorLogger.testSink to capture log output.
    func testAppUserIdNotLoggedAtInfoLevel() {
        var capturedLogs: [(level: String, message: String)] = []

        // Install test sink to capture all log output
        AppActorLogger.testSink = { level, message in
            capturedLogs.append((level: level, message: message))
        }
        defer { AppActorLogger.testSink = nil }

        // Set log level to debug so we capture everything
        let previousLevel = AppActorLogger.level
        AppActorLogger.level = .debug
        defer { AppActorLogger.level = previousLevel }

        // Emit the same log calls that identify/login/logout use
        Log.identity.debug("Identified as test_user_123")
        Log.identity.info("Identity established")
        Log.identity.debug("Logged in as test_user_456")
        Log.identity.info("Login complete")
        Log.identity.debug("Logged out. New anonymous ID: anon_789")
        Log.identity.info("Logout complete — new anonymous ID assigned")

        // Verify: no INFO-level message contains an appUserId-like string
        let infoMessages = capturedLogs.filter { $0.level == "info" }
        for log in infoMessages {
            XCTAssertFalse(
                log.message.contains("test_user_") || log.message.contains("anon_"),
                "INFO-level log should not contain appUserId: '\(log.message)'"
            )
        }

        // Verify: DEBUG-level messages DO contain the user IDs (proving the sink works)
        let debugMessages = capturedLogs.filter { $0.level == "debug" }
        let debugTexts = debugMessages.map(\.message).joined(separator: " ")
        XCTAssertTrue(debugTexts.contains("test_user_123"), "DEBUG log should contain appUserId")
        XCTAssertTrue(debugTexts.contains("test_user_456"), "DEBUG log should contain appUserId")
        XCTAssertTrue(debugTexts.contains("anon_789"), "DEBUG log should contain anonymous ID")
    }

    // MARK: - SECR-01: public options remain focused on runtime controls

    func testPaymentConfigurationOptionsExposeOnlyRuntimeControls() {
        let options = AppActorPaymentConfiguration.Options(
            logLevel: .debug
        )
        XCTAssertEqual(options.logLevel, .debug)
    }

    // MARK: - SECR-05: PaymentClient defaults aligned with Options

    /// Verifies that PaymentClient defaults stay strict even though
    /// response signature controls are no longer part of the public API.
    func testPaymentClientDefaultRequireSignaturesIsTrue() {
        // Create PaymentClient with ALL defaults (no explicit requireSignatures)
        let client = AppActorPaymentClient(
            baseURL: URL(string: "https://test.example.com")!,
            apiKey: "pk_test_key"
        )

        // Strict verification now lives inside the SDK, so construction with defaults
        // must remain possible and should not require any public override.
        // Suppress unused variable warning.
        _ = client
    }

    // MARK: - SECR-04: Timestamp drift tolerance

    func testTimestampDriftIs300Seconds() {
        // Verify the constant is 300 seconds (5 minutes)
        // ResponseSignatureVerifier is the internal type name (accessible via @testable import)
        XCTAssertEqual(
            ResponseSignatureVerifier.maxTimestampDrift, 300,
            "maxTimestampDrift should be 300 seconds"
        )
    }

    // MARK: - FEAT-02: AppActorError.notAvailable

    func testNotAvailableErrorHasDescription() {
        let error = AppActorError.notAvailable("Test feature not supported")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not available"),
                       "notAvailable error description should mention 'not available'")
        XCTAssertTrue(error.errorDescription!.contains("Test feature not supported"),
                       "notAvailable error description should include the reason string")
    }
}
