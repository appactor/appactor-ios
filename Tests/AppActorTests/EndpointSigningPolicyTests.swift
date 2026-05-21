import XCTest
@testable import AppActor

final class EndpointSigningPolicyTests: XCTestCase {

    // MARK: - Nonce-Free Endpoints

    func testOfferingsIsNonceFree() {
        let policy = EndpointSigningPolicy.forPath("/v1/payment/offerings")
        XCTAssertEqual(policy, .nonceFree)
        XCTAssertFalse(policy.needsNonce)
    }

    func testRemoteConfigIsNonceFree() {
        let policy = EndpointSigningPolicy.forPath("/v1/remote-config")
        XCTAssertEqual(policy, .nonceFree)
        XCTAssertFalse(policy.needsNonce)
    }

    // MARK: - Nonce-Required Endpoints

    func testIdentifyIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/payment/identify"), .nonceRequired)
    }

    func testLoginIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/payment/login"), .nonceRequired)
    }

    func testCustomerIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/customers/abc123"), .nonceRequired)
    }

    func testReceiptIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/payment/receipts/apple"), .nonceRequired)
    }

    func testRestoreIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/payment/restore/apple"), .nonceRequired)
    }

    func testExperimentsIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/experiments/some-key/assignments"), .nonceRequired)
    }

    func testASAIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/asa/attribution"), .nonceRequired)
    }

    func testUnknownPathIsNonceRequired() {
        XCTAssertEqual(EndpointSigningPolicy.forPath("/v1/something-new"), .nonceRequired)
    }

    // MARK: - needsNonce

    func testNonceRequiredNeedsNonce() {
        XCTAssertTrue(EndpointSigningPolicy.nonceRequired.needsNonce)
    }

    func testNonceFreeDoesNotNeedNonce() {
        XCTAssertFalse(EndpointSigningPolicy.nonceFree.needsNonce)
    }
}
