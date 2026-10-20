import Cocoa
import CoreFoundation
import InputMethodKit
import XCTest

/// Keeps the input-method connection and its bundle alive for the test process.
@MainActor
struct InputMethodTestServer {
    private static let processFixture = Result { try InputMethodTestServer() }

    static var shared: InputMethodTestServer {
        get throws { try processFixture.get() }
    }

    private let registeredBundle: CFBundle
    let bundle: Bundle
    let server: IMKServer

    private init() throws {
        _ = NSApplication.shared
        let identifier = "dev.azookey.tests.input-method.\(UUID().uuidString)"
        let connectionName = "\(identifier).connection"
        let controllerName = NSStringFromClass(InputMethodTestController.self)
        // Per-test document and learning directories are removed in tearDown.
        // This connection's metadata must outlive all of those test sessions.
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
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
        // A metadata-only NSBundle need not be registered for identifier lookup.
        // Keep its CFBundle alive so IMKServer can find the same metadata by ID.
        registeredBundle = try XCTUnwrap(CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL))
        _ = try XCTUnwrap(
            CFBundleGetBundleWithIdentifier(identifier as CFString),
            "Core Foundation must resolve the temporary input-method bundle"
        )
        bundle = try XCTUnwrap(
            Bundle(identifier: identifier),
            "InputMethodKit must resolve the registered bundle at \(bundleURL.path)"
        )
        _ = try XCTUnwrap(NSClassFromString(controllerName), "The bundle must name the actual input controller")
        server = try XCTUnwrap(IMKServer(name: connectionName, bundleIdentifier: identifier))
    }
}
