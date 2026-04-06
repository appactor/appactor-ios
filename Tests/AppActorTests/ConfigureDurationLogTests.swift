import XCTest
@testable import AppActor

@MainActor
final class ConfigureDurationLogTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var capturedLogs: [(level: String, message: String)] = []

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        capturedLogs = []

        AppActorLogger.level = .debug
        AppActorLogger.testSink = { [weak self] level, message in
            self?.capturedLogs.append((level, message))
        }
    }

    override func tearDown() {
        AppActorLogger.testSink = nil
        AppActorLogger.level = .info
        appactor.asaTask?.cancel()
        appactor.asaTask = nil
        appactor.foregroundTask?.cancel()
        appactor.foregroundTask = nil
        appactor.offeringsPrefetchTask?.cancel()
        appactor.offeringsPrefetchTask = nil
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
        appactor.paymentCurrentUser = nil
        appactor.paymentETagManager = nil
        appactor.offeringsManager = nil
        appactor.customerManager = nil
        appactor.remoteConfigManager = nil
        appactor.experimentManager = nil
        appactor.paymentProcessor = nil
        appactor.transactionWatcher = nil
        appactor.paymentQueueStore = nil
        appactor.paymentLifecycle = .idle
        super.tearDown()
    }

    // MARK: - Tests

    func testBootstrapLogsDuration() async {
        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_duration",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(config: config, client: mockClient, storage: storage)
        await appactor.runStartupSequence()

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

        let stepNames = ["setup", "identify", "sweepUnfinished", "syncPurchases+customerInfo"]
        for step in stepNames {
            let found = capturedLogs.contains { $0.message.contains("⏱ \(step):") }
            XCTAssertTrue(found, "Expected timing log for step '\(step)'")
        }
    }
}
