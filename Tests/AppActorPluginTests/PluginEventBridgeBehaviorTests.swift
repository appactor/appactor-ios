import XCTest
@testable import AppActor
import AppActorPlugin

private final class RecordingPluginDelegate: NSObject, AppActorPluginDelegate {
    var onEvent: ((String, String) -> Void)?
    private(set) var events: [(name: String, json: String)] = []

    func appActorPlugin(
        _ plugin: AppActorPlugin,
        didReceiveEvent eventName: String,
        withJson jsonString: String
    ) {
        events.append((name: eventName, json: jsonString))
        onEvent?(eventName, jsonString)
    }
}

@MainActor
final class PluginEventBridgeBehaviorTests: XCTestCase {

    func testStartAndStopListeningDoNotTouchPurchaseIntentStorage() {
        let appActor = AppActor.shared
        let originalCustomerListener = appActor.onCustomerInfoChanged
        let originalReceiptListener = appActor.onReceiptPipelineEvent
        let originalPurchaseIntentStorage = appActor._onPurchaseIntent
        let marker = NSObject()

        defer {
            AppActorPlugin.shared.stopEventListening()
            appActor.onCustomerInfoChanged = originalCustomerListener
            appActor.onReceiptPipelineEvent = originalReceiptListener
            appActor._onPurchaseIntent = originalPurchaseIntentStorage
            AppActorPlugin.shared.delegate = nil
        }

        appActor._onPurchaseIntent = marker

        AppActorPlugin.shared.startEventListening()
        XCTAssertTrue((appActor._onPurchaseIntent as AnyObject?) === marker)

        AppActorPlugin.shared.stopEventListening()
        XCTAssertTrue((appActor._onPurchaseIntent as AnyObject?) === marker)
    }

    func testEventListeningOnlyEmitsCustomerAndReceiptEvents() async throws {
        let appActor = AppActor.shared
        let originalCustomerListener = appActor.onCustomerInfoChanged
        let originalReceiptListener = appActor.onReceiptPipelineEvent
        let originalPurchaseIntentStorage = appActor._onPurchaseIntent
        let delegate = RecordingPluginDelegate()
        let expectation = XCTestExpectation(description: "plugin delegate receives supported events")
        expectation.expectedFulfillmentCount = 2

        defer {
            AppActorPlugin.shared.stopEventListening()
            appActor.onCustomerInfoChanged = originalCustomerListener
            appActor.onReceiptPipelineEvent = originalReceiptListener
            appActor._onPurchaseIntent = originalPurchaseIntentStorage
            AppActorPlugin.shared.delegate = nil
        }

        delegate.onEvent = { _, _ in
            expectation.fulfill()
        }
        AppActorPlugin.shared.delegate = delegate
        AppActorPlugin.shared.startEventListening()

        let customerInfo = AppActorCustomerInfo(appUserId: "user_123")
        appActor.onCustomerInfoChanged?(customerInfo)

        let receiptDetail = AppActorReceiptPipelineEventDetail(
            event: .postedOk(transactionId: "tx_123"),
            productId: "com.app.monthly",
            appUserId: "user_123"
        )
        appActor.onReceiptPipelineEvent?(receiptDetail)

        await fulfillment(of: [expectation], timeout: 5.0)

        XCTAssertEqual(delegate.events.map(\.name), [
            "customer_info_updated",
            "receipt_pipeline_event",
        ])
        XCTAssertFalse(delegate.events.map(\.name).contains("purchase_intent"))

        let customerPayload = try parseJSON(delegate.events[0].json)
        XCTAssertEqual(customerPayload["app_user_id"] as? String, "user_123")

        let receiptPayload = try parseJSON(delegate.events[1].json)
        XCTAssertEqual(receiptPayload["type"] as? String, "posted_ok")
        XCTAssertEqual(receiptPayload["transaction_id"] as? String, "tx_123")
        XCTAssertEqual(receiptPayload["product_id"] as? String, "com.app.monthly")
        XCTAssertEqual(receiptPayload["app_user_id"] as? String, "user_123")
    }

    private func parseJSON(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
