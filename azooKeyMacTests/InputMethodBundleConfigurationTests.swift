import Cocoa
import XCTest

@testable import azooKeyMac

@MainActor
final class InputMethodBundleConfigurationTests: XCTestCase {
    func testConfiguredControllerResolvesToInputMethodImplementation() throws {
        // The SwiftPM test harness symlinks its sources into build/macos-app.
        let repositoryURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let propertiesURL = repositoryURL.appendingPathComponent("azooKeyMac/Info.plist")
        let properties = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: propertiesURL), options: [], format: nil
            ) as? [String: Any]
        )
        let controllerName = try XCTUnwrap(properties["InputMethodServerControllerClass"] as? String)
            .replacingOccurrences(of: "$(PRODUCT_MODULE_NAME)", with: "azooKeyMac")
        let controllerClass = try XCTUnwrap(NSClassFromString(controllerName))
        XCTAssertEqual(ObjectIdentifier(controllerClass), ObjectIdentifier(azooKeyMacInputController.self))
        XCTAssertEqual(controllerName, NSStringFromClass(azooKeyMacInputController.self))
    }
}
