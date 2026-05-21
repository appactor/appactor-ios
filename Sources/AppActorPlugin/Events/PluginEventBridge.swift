import Foundation
@_spi(AppActorPluginSupport) import AppActor

// MARK: - Event Protocol

/// Type-safe event with a constant identifier for cross-platform routing.
protocol AppActorPluginEvent: Encodable, Sendable {
    var id: String { get }
}

// MARK: - Event Types

struct SdkLogEvent: AppActorPluginEvent {
    let id = "sdk_log"
    let level: String
    let message: String
    let category: String
    let timestamp: String
}

@available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
struct PurchaseIntentEvent: AppActorPluginEvent {
    let id = "purchase_intent_received"
    let intentId: String
    let productId: String
    let offerId: String?
    let offerType: String?
}

struct DeferredPurchaseResolvedEvent: AppActorPluginEvent {
    let id = "deferred_purchase_resolved"
    let productId: String
    let customerInfo: PluginCustomerInfo
}

struct ReceiptPipelineEvent: AppActorPluginEvent {
    let id = "receipt_pipeline_event"
    let type: String
    let transactionId: String?
    let productId: String
    let appUserId: String
    let retryCount: Int?
    let nextAttemptAt: String?
    let errorCode: String?
    let key: String?

    init(from event: AppActorBridgeReceiptEvent) {
        self.type = event.type.lowercased()
        self.transactionId = event.transactionId
        self.productId = event.productId
        self.appUserId = event.appUserId
        self.retryCount = event.retryCount
        self.nextAttemptAt = event.nextAttemptAt
        self.errorCode = event.errorCode
        self.key = event.key
    }
}

// MARK: - Event Bridge

/// Wires SDK callbacks to the plugin delegate as JSON events.
@MainActor
final class AppActorPluginEventBridge {

    static let shared = AppActorPluginEventBridge()
    private init() {}

    private var listening = false
    private var previousCustomerInfoListener: ((AppActorCustomerInfo) -> Void)?
    private var previousReceiptPipelineListener: (@Sendable (AppActorReceiptPipelineEventDetail) -> Void)?
    private var previousDeferredPurchaseListener: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)?
    private var ownsPurchaseIntentListener = false

    func startListening() {
        guard !listening else { return }
        listening = true

        previousCustomerInfoListener = AppActor.shared.onCustomerInfoChanged
        previousReceiptPipelineListener = AppActor.shared.onReceiptPipelineEvent

        AppActor.shared.onCustomerInfoChanged = { customerInfo in
            self.previousCustomerInfoListener?(customerInfo)
            self.emitEncodable("customer_info_updated", PluginCustomerInfo(from: customerInfo))
        }

        let capturedPipelineListener = previousReceiptPipelineListener
        AppActor.shared.onReceiptPipelineEvent = { detail in
            capturedPipelineListener?(detail)
            Task { @MainActor in
                let bridgeEvent = AppActorBridgeReceiptEvent(from: detail)
                self.emit(ReceiptPipelineEvent(from: bridgeEvent))
            }
        }

        previousDeferredPurchaseListener = AppActor.shared.onDeferredPurchaseResolved
        AppActor.shared.onDeferredPurchaseResolved = { productId, customerInfo in
            self.previousDeferredPurchaseListener?(productId, customerInfo)
            self.emit(DeferredPurchaseResolvedEvent(
                productId: productId,
                customerInfo: PluginCustomerInfo(from: customerInfo)
            ))
        }

        // Note: Unlike onCustomerInfoChanged/onReceiptPipelineEvent, the log handler
        // has no public getter, so we cannot save/restore a previous handler. The plugin
        // is expected to be the sole consumer of setLogHandler.
        AppActor.setLogHandler { level, message, category, date in
            Task { @MainActor in
                self.emit(SdkLogEvent(
                    level: level,
                    message: message,
                    category: category,
                    timestamp: AppActorPluginCoder.isoDateFormatter.string(from: date)
                ))
            }
        }

        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if !AppActor.shared.hasPurchaseIntentStorage {
                ownsPurchaseIntentListener = true
                AppActor.shared.onPurchaseIntent = { intent in
                    Task { @MainActor in
                        let intentId = PurchaseIntentStore.shared.store(intent)
                        var offerId: String?
                        var offerType: String?
                        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *) {
                            offerId = intent.offer?.id
                            offerType = intent.offer.map { offer in
                                switch offer.type {
                                case .winBack: return "win_back"
                                default: return "unknown"
                                }
                            }
                        }
                        self.emit(PurchaseIntentEvent(
                            intentId: intentId,
                            productId: intent.product.id,
                            offerId: offerId,
                            offerType: offerType
                        ))
                    }
                }
            }
        }
    }

    func stopListening() {
        guard listening else { return }
        listening = false

        AppActor.setLogHandler(nil)
        AppActor.shared.onCustomerInfoChanged = previousCustomerInfoListener
        AppActor.shared.onReceiptPipelineEvent = previousReceiptPipelineListener
        AppActor.shared.onDeferredPurchaseResolved = previousDeferredPurchaseListener
        previousCustomerInfoListener = nil
        previousReceiptPipelineListener = nil
        previousDeferredPurchaseListener = nil

        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if ownsPurchaseIntentListener {
                AppActor.shared.onPurchaseIntent = nil
            }
            ownsPurchaseIntentListener = false
        }
    }

    private func emit<T: AppActorPluginEvent>(_ event: T) {
        emitEncodable(event.id, event)
    }

    private func emitEncodable<T: Encodable>(_ eventName: String, _ value: T) {
        let json: String
        do {
            let data = try AppActorPluginCoder.encoder.encode(value)
            json = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            assertionFailure("AppActorPlugin: Failed to encode event '\(eventName)': \(error)")
            json = "{}"
        }
        AppActorPlugin.shared.delegate?.appActorPlugin(
            AppActorPlugin.shared,
            didReceiveEvent: eventName,
            withJson: json
        )
    }
}
