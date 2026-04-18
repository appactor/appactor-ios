import XCTest
@testable import AppActorPlugin
@_spi(AppActorPluginSupport) import AppActor

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

    func testConfigureRequestDecodesCanonicalNestedOptionsPayload() throws {
        let json = """
        {
          "api_key": "pk_test_123",
          "platform_flavor": "legacy",
          "platform_version": "0.9.0",
          "options": {
            "log_level": "debug",
            "platform_info": {
              "flavor": "flutter",
              "version": "1.2.3"
            }
          }
        }
        """

        let request = try AppActorPluginCoder.decoder.decode(
            ConfigureRequest.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(request.apiKey, "pk_test_123")
        XCTAssertEqual(request.resolvedOptions().logLevel, .debug)
        XCTAssertEqual(
            request.resolvedOptions().platformInfo,
            AppActorPlatformInfo(flavor: "flutter", version: "1.2.3")
        )
    }

    func testConfigureRequestKeepsLegacyTopLevelPlatformAliasesDuringMigration() throws {
        let request = try AppActorPluginCoder.decoder.decode(
            ConfigureRequest.self,
            from: Data(#"{"api_key":"pk_test_123","platform_info":{"flavor":"flutter","version":"1.2.3"}}"#.utf8)
        )

        XCTAssertEqual(
            request.resolvedOptions().platformInfo,
            AppActorPlatformInfo(flavor: "flutter", version: "1.2.3")
        )
    }

    func testConfigureRequestLeavesPlatformInfoNilWhenOmitted() throws {
        let request = try AppActorPluginCoder.decoder.decode(
            ConfigureRequest.self,
            from: Data(#"{"api_key":"pk_test_123"}"#.utf8)
        )

        XCTAssertNil(request.resolvedOptions().platformInfo)
    }

    func testConfigureRequestVersionOnlyFallsBackToFlutterFlavor() throws {
        let request = try AppActorPluginCoder.decoder.decode(
            ConfigureRequest.self,
            from: Data(#"{"api_key":"pk_test_123","platform_version":"1.2.3"}"#.utf8)
        )

        XCTAssertEqual(
            request.resolvedOptions().platformInfo,
            AppActorPlatformInfo(flavor: "flutter", version: "1.2.3")
        )
    }

    func testGetOfferingsRequestDecodesCanonicalFetchPolicyKey() throws {
        let request = try AppActorPluginCoder.decoder.decode(
            GetOfferingsRequest.self,
            from: Data(#"{"fetch_policy":"cacheOnly"}"#.utf8)
        )

        XCTAssertEqual(request.fetchPolicy, "cacheOnly")
    }

    private func parseEnvelope(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
