import XCTest
@testable import AppActor

final class ExperimentManagerTests: XCTestCase {

    private var client: MockPaymentClient!
    private var etagManager: AppActorETagManager!
    private var currentDate: Date!
    private var manager: AppActorExperimentManager!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        etagManager = AppActorETagManager()
        currentDate = Date()
        manager = AppActorExperimentManager(
            client: client,
            etagManager: etagManager,
            dateProvider: { [unowned self] in self.currentDate }
        )
    }

    private func assignmentDTO(
        variantKey: String,
        payload: AppActorConfigValue = .string("payload")
    ) -> AppActorExperimentAssignmentDTO {
        AppActorExperimentAssignmentDTO(
            inExperiment: true,
            reason: nil,
            experiment: AppActorExperimentAssignmentDTO.ExperimentRef(id: "exp_\(variantKey)", key: "paywall_copy"),
            variant: AppActorExperimentAssignmentDTO.VariantRef(
                id: "var_\(variantKey)",
                key: variantKey,
                valueType: "string",
                payload: payload
            ),
            assignedAt: "2026-03-14T12:00:00Z"
        )
    }

    func testAppVersionChangeBypassesFreshAssignmentCache() async throws {
        client.postExperimentAssignmentHandler = { [weak self] _, _, appVersion, _ in
            guard let self else { throw AppActorError.notConfigured }
            let variant = appVersion == "2.0.0" ? "variant_v2" : "variant_v1"
            return .success(self.assignmentDTO(variantKey: variant), requestId: "req_\(variant)", signatureVerified: false)
        }

        let first = try await manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: "1.0.0",
            country: "TR"
        )
        XCTAssertEqual(first?.variantKey, "variant_v1")

        currentDate = currentDate.addingTimeInterval(120)

        let second = try await manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: "2.0.0",
            country: "TR"
        )
        XCTAssertEqual(second?.variantKey, "variant_v2")
        XCTAssertEqual(client.postExperimentAssignmentCalls.count, 2)
    }

    func testInFlightDoesNotCoalesceDifferentTargetingContexts() async throws {
        client.postExperimentAssignmentHandler = { [weak self] _, _, appVersion, _ in
            guard let self else { throw AppActorError.notConfigured }
            try await Task.sleep(nanoseconds: 50_000_000)
            let variant = appVersion == "2.0.0" ? "variant_v2" : "variant_v1"
            return .success(self.assignmentDTO(variantKey: variant), requestId: "req_\(variant)", signatureVerified: false)
        }

        async let first = manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: "1.0.0",
            country: "TR"
        )
        async let second = manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: "2.0.0",
            country: "TR"
        )

        let results = try await [first, second]
        XCTAssertEqual(results[0]?.variantKey, "variant_v1")
        XCTAssertEqual(results[1]?.variantKey, "variant_v2")
        XCTAssertEqual(client.postExperimentAssignmentCalls.count, 2)
    }

    func testClearCacheRemovesAllContextVariantsForUser() async throws {
        client.postExperimentAssignmentHandler = { [weak self] _, _, appVersion, _ in
            guard let self else { throw AppActorError.notConfigured }
            let variant = appVersion == "2.0.0" ? "variant_v2" : "variant_v1"
            return .success(self.assignmentDTO(variantKey: variant), requestId: "req_\(variant)", signatureVerified: false)
        }

        _ = try await manager.getAssignment(experimentKey: "paywall_copy", appUserId: "user_A", appVersion: "1.0.0", country: "TR")
        _ = try await manager.getAssignment(experimentKey: "paywall_copy", appUserId: "user_A", appVersion: "2.0.0", country: "TR")
        XCTAssertEqual(client.postExperimentAssignmentCalls.count, 2)

        await manager.clearCache(appUserId: "user_A")

        currentDate = currentDate.addingTimeInterval(120)
        let refetched = try await manager.getAssignment(experimentKey: "paywall_copy", appUserId: "user_A", appVersion: "1.0.0", country: "TR")
        XCTAssertEqual(refetched?.variantKey, "variant_v1")
        XCTAssertEqual(client.postExperimentAssignmentCalls.count, 3)
    }

    func testClearCacheCancelsInFlightAndPreventsStaleAssignmentWrite() async throws {
        client.postExperimentAssignmentHandler = { [weak self] _, _, _, _ in
            guard let self else { throw AppActorError.notConfigured }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                // Simulate a transport layer that still returns after cancellation.
            }
            return .success(self.assignmentDTO(variantKey: "stale"), requestId: "req_stale", signatureVerified: false)
        }

        let fetchTask = Task<AppActorExperimentAssignment?, Error> {
            try await manager.getAssignment(
                experimentKey: "paywall_copy",
                appUserId: "user_A",
                appVersion: "1.0.0",
                country: "TR"
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.clearCache(appUserId: "user_A")

        do {
            _ = try await fetchTask.value
            XCTFail("Expected in-flight experiment fetch to be cancelled after clearCache")
        } catch is CancellationError {
            // Expected: stale assignment must not repopulate cache after invalidation.
        }

        let cachedAfterClear = await manager.cached(experimentKey: "paywall_copy")
        XCTAssertNil(cachedAfterClear)

        client.postExperimentAssignmentHandler = { [weak self] _, _, _, _ in
            guard let self else { throw AppActorError.notConfigured }
            return .success(self.assignmentDTO(variantKey: "fresh"), requestId: "req_fresh", signatureVerified: false)
        }

        let refetched = try await manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: "1.0.0",
            country: "TR"
        )
        XCTAssertEqual(refetched?.variantKey, "fresh")
        XCTAssertEqual(client.postExperimentAssignmentCalls.count, 2)
    }

    func testDiskFallbackDoesNotLeakAnotherUsersExperimentCache() async throws {
        client.postExperimentAssignmentHandler = { _, _, _, _ in
            .success(
                AppActorExperimentAssignmentDTO(
                    inExperiment: true,
                    reason: nil,
                    experiment: AppActorExperimentAssignmentDTO.ExperimentRef(id: "exp_A", key: "paywall_copy"),
                    variant: AppActorExperimentAssignmentDTO.VariantRef(
                        id: "var_A",
                        key: "variant_A",
                        valueType: "string",
                        payload: AppActorConfigValue.string("copy_A")
                    ),
                    assignedAt: "2026-03-14T12:00:00Z"
                ),
                requestId: "req_exp_seed",
                signatureVerified: false
            )
        }

        _ = try await manager.getAssignment(
            experimentKey: "paywall_copy",
            appUserId: "user_A",
            appVersion: nil,
            country: nil
        )

        let secondClient = MockPaymentClient()
        secondClient.postExperimentAssignmentHandler = { _, _, _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }
        let secondManager = AppActorExperimentManager(
            client: secondClient,
            etagManager: etagManager,
            dateProvider: { [unowned self] in self.currentDate }
        )

        do {
            _ = try await secondManager.getAssignment(
                experimentKey: "paywall_copy",
                appUserId: "user_B",
                appVersion: nil,
                country: nil
            )
            XCTFail("Expected user-scoped disk fallback to miss for a different user")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .network)
        }
    }
}
