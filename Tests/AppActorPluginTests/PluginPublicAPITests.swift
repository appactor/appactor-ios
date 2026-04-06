import XCTest
import AppActorPlugin

private struct PublicSuccessPayload: Encodable {
    let message: String
}

private struct PublicSuccessRequest: AppActorPluginRequest {
    static let method = "plugin_public_success_request"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        AppActorPluginResult.encoding(PublicSuccessPayload(message: "ok"))
    }
}

private struct PublicErrorRequest: AppActorPluginRequest {
    static let method = "plugin_public_error_request"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        .error(AppActorPluginError(code: 9100, message: "Custom error", detail: "from test"))
    }
}

@MainActor
final class PluginPublicAPITests: XCTestCase {

    override func tearDown() {
        AppActorPlugin.shared.remove(methods: [
            PublicSuccessRequest.method,
            PublicErrorRequest.method,
        ])
        super.tearDown()
    }

    func testCustomRequestRegistrationWorks() async throws {
        let plugin = AppActorPlugin.shared
        plugin.register(requests: [PublicSuccessRequest.self])

        XCTAssertTrue(plugin.registeredMethods.contains(PublicSuccessRequest.method))

        let json = await plugin.execute(method: PublicSuccessRequest.method, withJson: "{}")
        let envelope = try parseEnvelope(json)
        let success = try XCTUnwrap(envelope["success"] as? [String: Any])
        XCTAssertEqual(success["message"] as? String, "ok")
    }

    func testCustomRequestErrorEnvelopeWorks() async throws {
        let plugin = AppActorPlugin.shared
        plugin.register(requests: [PublicErrorRequest.self])

        let json = await plugin.execute(method: PublicErrorRequest.method, withJson: "{}")
        let envelope = try parseEnvelope(json)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 9100)
        XCTAssertEqual(error["message"] as? String, "Custom error")
        XCTAssertEqual(error["detail"] as? String, "from test")
    }

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
