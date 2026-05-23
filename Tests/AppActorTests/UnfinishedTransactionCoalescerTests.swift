import XCTest
@testable import AppActor

final class UnfinishedTransactionCoalescerTests: XCTestCase {
    func testPassiveRenewalBacklogSelectsLatestRepresentativePerOriginalChain() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "200", originalId: "100", purchaseDate: baseDate),
                candidate(id: "201", originalId: "100", purchaseDate: baseDate.addingTimeInterval(60)),
                candidate(id: "202", originalId: "100", purchaseDate: baseDate.addingTimeInterval(30))
            ]
        )

        XCTAssertEqual(selected, ["201"])
    }

    func testDifferentOriginalChainsAreKeptIndependently() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "200", originalId: "100", purchaseDate: baseDate),
                candidate(id: "201", originalId: "100", purchaseDate: baseDate.addingTimeInterval(60)),
                candidate(id: "300", originalId: "300", reason: .purchase, purchaseDate: baseDate),
                candidate(id: "401", originalId: "400", purchaseDate: baseDate)
            ]
        )

        XCTAssertEqual(selected, ["201", "300", "401"])
    }

    func testInitialPurchasesAreAlwaysKept() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "100", originalId: "100", reason: .purchase, purchaseDate: baseDate),
                candidate(id: "101", originalId: "100", purchaseDate: baseDate.addingTimeInterval(60))
            ]
        )

        XCTAssertEqual(selected, ["100", "101"])
    }

    func testRevokedRenewalsAreKeptEvenWhenSameChainHasNewerPassiveRenewal() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "200", originalId: "100", purchaseDate: baseDate),
                candidate(
                    id: "201",
                    originalId: "100",
                    purchaseDate: baseDate.addingTimeInterval(60),
                    revocationDate: baseDate.addingTimeInterval(120)
                ),
                candidate(id: "202", originalId: "100", purchaseDate: baseDate.addingTimeInterval(30))
            ]
        )

        XCTAssertEqual(selected, ["201", "202"])
    }

    func testBlankOriginalTransactionIdIsNotCoalesced() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "200", originalId: nil, purchaseDate: baseDate),
                candidate(id: "201", originalId: "", purchaseDate: baseDate.addingTimeInterval(60))
            ]
        )

        XCTAssertEqual(selected, ["200", "201"])
    }

    func testEqualPurchaseDateUsesTransactionIdTieBreak() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = AppActorUnfinishedTransactionCoalescer.selectRepresentativeIds(
            from: [
                candidate(id: "99", originalId: "50", purchaseDate: baseDate),
                candidate(id: "100", originalId: "50", purchaseDate: baseDate)
            ]
        )

        XCTAssertEqual(selected, ["100"])
    }

    private func candidate(
        id: String,
        originalId: String?,
        productId: String = "com.test.weekly",
        reason: AppActorTransactionReason = .renewal,
        purchaseDate: Date,
        revocationDate: Date? = nil
    ) -> AppActorUnfinishedTransactionCandidate {
        AppActorUnfinishedTransactionCandidate(
            transactionId: id,
            originalTransactionId: originalId,
            productId: productId,
            purchaseDate: purchaseDate,
            revocationDate: revocationDate,
            reason: reason
        )
    }
}
