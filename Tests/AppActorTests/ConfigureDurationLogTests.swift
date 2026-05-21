import XCTest
@testable import AppActor

@MainActor
final class ConfigureDurationLogTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var logCollector: LockedLogCollector!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        logCollector = LockedLogCollector()

        AppActorLogger.level = .debug
        let logCollector = logCollector
        AppActorLogger.testSink = { level, message in
            logCollector?.append(level: level, message: message)
        }
    }

    override func tearDown() async throws {
        AppActorLogger.testSink = nil
        AppActorLogger.level = .info
        await appactor.reset()
        logCollector = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testBootstrapLogsDuration() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_duration",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        let capturedLogs = logCollector.snapshot()
        let bootstrapLogs = capturedLogs.filter {
            $0.message.contains("bootstrap:")
        }
        XCTAssertEqual(bootstrapLogs.count, 1, "Expected exactly one bootstrap log line")
        XCTAssertTrue(bootstrapLogs[0].message.contains("ms"), "Duration should include 'ms'")

        let configureLogs = capturedLogs.filter {
            $0.message.contains("Configure total:")
        }
        XCTAssertEqual(configureLogs.count, 1, "Expected exactly one configure total log line")
        XCTAssertTrue(configureLogs[0].message.contains("ms"), "Duration should include 'ms'")
    }

    func testBootstrapLogsEachStep() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_steps",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

        let capturedLogs = logCollector.snapshot()
        let stepNames = ["setup", "offerings/api", "sweepUnfinished", "drainReceiptQueueAndRefreshCustomer"]
        for step in stepNames {
            let found = capturedLogs.contains { $0.message.contains("⏱ \(step):") }
            XCTAssertTrue(found, "Expected timing log for step '\(step)'")
        }
    }
}
