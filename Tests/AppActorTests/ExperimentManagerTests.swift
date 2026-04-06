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
