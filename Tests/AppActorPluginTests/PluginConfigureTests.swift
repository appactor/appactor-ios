import XCTest
import AppActorPlugin

@MainActor
final class PluginConfigureTests: XCTestCase {

    func testConfigureRejectsBlankAPIKey() async throws {
        let json = await AppActorPlugin.shared.execute(
            method: "configure",
            withJson: #"{"api_key":"   "}"#
        )
        let envelope = try parseEnvelope(json)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, 2003)
        XCTAssertEqual(error["message"] as? String, "[AppActor] Validation: apiKey must not be blank.")
    }

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
