import Foundation

struct AppActorUnfinishedTransactionCandidate: Sendable, Equatable {
    let transactionId: String
    let originalTransactionId: String?
    let productId: String
    let purchaseDate: Date
    let revocationDate: Date?
    let reason: AppActorTransactionReason
}

struct AppActorUnfinishedTransactionCoalescer {
    static func selectRepresentativeIds(
        from candidates: [AppActorUnfinishedTransactionCandidate]
    ) -> Set<String> {
        var selected = Set<String>()
        var passiveRenewalsByOriginalId: [String: AppActorUnfinishedTransactionCandidate] = [:]

        for candidate in candidates {
            guard
                candidate.revocationDate == nil,
                candidate.reason == .renewal,
                let originalTransactionId = candidate.originalTransactionId?.nilIfBlank,
                candidate.transactionId != originalTransactionId
            else {
                selected.insert(candidate.transactionId)
                continue
            }

            if let existing = passiveRenewalsByOriginalId[originalTransactionId] {
                passiveRenewalsByOriginalId[originalTransactionId] = latestRepresentative(existing, candidate)
            } else {
                passiveRenewalsByOriginalId[originalTransactionId] = candidate
            }
        }

        for representative in passiveRenewalsByOriginalId.values {
            selected.insert(representative.transactionId)
        }

        return selected
    }

    private static func latestRepresentative(
        _ lhs: AppActorUnfinishedTransactionCandidate,
        _ rhs: AppActorUnfinishedTransactionCandidate
    ) -> AppActorUnfinishedTransactionCandidate {
        if lhs.purchaseDate != rhs.purchaseDate {
            return lhs.purchaseDate > rhs.purchaseDate ? lhs : rhs
        }

        if let lhsNumeric = UInt64(lhs.transactionId),
           let rhsNumeric = UInt64(rhs.transactionId),
           lhsNumeric != rhsNumeric {
            return lhsNumeric > rhsNumeric ? lhs : rhs
        }

        return lhs.transactionId > rhs.transactionId ? lhs : rhs
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
