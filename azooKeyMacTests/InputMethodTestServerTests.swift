import Cocoa
import CoreFoundation
import XCTest

@MainActor
final class InputMethodTestServerTests: XCTestCase {
    func testSharedServerKeepsItsResolvableBundleAndController() throws {
        let fixture = try InputMethodTestServer.shared
        let identifier = try XCTUnwrap(fixture.bundle.bundleIdentifier)
        let resolvedBundle = try XCTUnwrap(Bundle(identifier: identifier))
        XCTAssertEqual(resolvedBundle.bundleURL, fixture.bundle.bundleURL)
        let coreBundle = try XCTUnwrap(CFBundleGetBundleWithIdentifier(identifier as CFString))
        let coreURL = try XCTUnwrap(CFBundleCopyBundleURL(coreBundle))
        XCTAssertEqual((coreURL as URL).standardizedFileURL, fixture.bundle.bundleURL.standardizedFileURL)
        XCTAssertEqual(
            resolvedBundle.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String,
            NSStringFromClass(InputMethodTestController.self)
        )
        XCTAssertEqual(
            resolvedBundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
            "\(identifier).connection"
        )
    }

    func testSeparateAccessesKeepTheSameServerAndBundleAlive() throws {
        let serverIdentity = try autoreleasepool {
            ObjectIdentifier(try InputMethodTestServer.shared.server)
        }
        let fixture = try InputMethodTestServer.shared
        XCTAssertEqual(ObjectIdentifier(fixture.server), serverIdentity)
        let propertiesURL = fixture.bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: propertiesURL.path))
        let properties = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: propertiesURL), options: .init(), format: nil
            ) as? [String: Any]
        )
        let identifier = try XCTUnwrap(fixture.bundle.bundleIdentifier)
        XCTAssertEqual(properties["CFBundleIdentifier"] as? String, identifier)
    }
}
