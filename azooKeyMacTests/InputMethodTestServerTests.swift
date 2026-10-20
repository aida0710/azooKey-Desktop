import Cocoa
import CoreFoundation
import XCTest

@testable import azooKeyMac

@MainActor
final class InputMethodTestServerTests: XCTestCase {
    func testTemporaryServersKeepTheirOwnResolvableBundleAndController() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try InputMethodTestServer(
            directoryURL: directory.appendingPathComponent("first"), controllerClass: azooKeyMacInputController.self
        )
        let second = try InputMethodTestServer(
            directoryURL: directory.appendingPathComponent("second"), controllerClass: azooKeyMacInputController.self
        )
        let firstIdentifier = try XCTUnwrap(first.bundle.bundleIdentifier)
        let secondIdentifier = try XCTUnwrap(second.bundle.bundleIdentifier)
        XCTAssertNotEqual(firstIdentifier, secondIdentifier)

        for fixture in [first, second] {
            let identifier = try XCTUnwrap(fixture.bundle.bundleIdentifier)
            let resolvedBundle = try XCTUnwrap(Bundle(identifier: identifier))
            XCTAssertEqual(resolvedBundle.bundleURL, fixture.bundle.bundleURL)
            let coreBundle = try XCTUnwrap(CFBundleGetBundleWithIdentifier(identifier as CFString))
            let coreURL = try XCTUnwrap(CFBundleCopyBundleURL(coreBundle))
            XCTAssertEqual((coreURL as URL).standardizedFileURL, fixture.bundle.bundleURL.standardizedFileURL)
            XCTAssertEqual(
                resolvedBundle.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String,
                NSStringFromClass(azooKeyMacInputController.self)
            )
            XCTAssertEqual(
                resolvedBundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
                "\(identifier).connection"
            )
        }
    }
}
