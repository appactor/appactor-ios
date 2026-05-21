import XCTest
@testable import AppActorPlugin
import AppActor

@MainActor
final class PluginResultTests: XCTestCase {

    func testSuccessVoidEnvelope() {
        let result = AppActorPluginResult.successVoid
        let json = result.jsonString
        XCTAssertTrue(json.contains("\"success\""))
    }

    func testErrorEnvelope() {
        let error = AppActorPluginError(code: 1003, message: "Unknown method", detail: "test")
        let result = AppActorPluginResult.error(error)
        let json = result.jsonString
        let data = Data(json.utf8)
        let envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let errorObj = envelope["error"] as! [String: Any]
        XCTAssertEqual(errorObj["code"] as? Int, 1003)
        XCTAssertEqual(errorObj["message"] as? String, "Unknown method")
    }

    func testSuccessEncodableEnvelope() {
        struct Foo: Encodable { let name: String }
        let result = AppActorPluginResult.encoding(Foo(name: "bar"))
        let json = result.jsonString
        let data = Data(json.utf8)
        let envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let success = envelope["success"] as! [String: Any]
        XCTAssertEqual(success["name"] as? String, "bar")
    }

    func testUnknownMethodRoute() async {
        let result = await AppActorPluginRequestRouter.route(
            method: "nonexistent", jsonData: Data("{}".utf8))
        let json = result.jsonString
        let data = Data(json.utf8)
        let envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let errorObj = envelope["error"] as! [String: Any]
        XCTAssertEqual(errorObj["code"] as? Int, AppActorPluginError.unknownMethod)
    }
}
