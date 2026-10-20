import Cocoa
import InputMethodKit
import XCTest

/// Holds the bundle metadata that the production IMKServer initializer reads.
@MainActor
struct InputMethodTestServer {
    let bundle: Bundle
    let server: IMKServer

    init(directoryURL: URL, controllerClass: AnyClass) throws {
        let identifier = "dev.azookey.tests.input-method.\(UUID().uuidString)"
        let connectionName = "\(identifier).connection"
        let controllerName = NSStringFromClass(controllerClass)
        let bundleURL = directoryURL.appendingPathComponent("InputMethodTests.bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let properties: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "InputMethodTests",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
            "LSBackgroundOnly": true,
            "InputMethodConnectionName": connectionName,
            "InputMethodServerControllerClass": controllerName,
            "tsInputMethodCharacterRepertoireKey": ["Latn", "Hira", "Kana"]
        ]
        let content = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        try content.write(to: contentsURL.appendingPathComponent("Info.plist"))
        bundle = try XCTUnwrap(Bundle(url: bundleURL))
        _ = try XCTUnwrap(Bundle(identifier: identifier), "InputMethodKit must be able to resolve its bundle")
        _ = try XCTUnwrap(NSClassFromString(controllerName), "The bundle must name the actual input controller")
        server = try XCTUnwrap(IMKServer(name: connectionName, bundleIdentifier: identifier))
    }
}
