import Foundation
import Testing

/// Locates the helper beside the running SwiftPM tests, including macOS's XCTest bundle.
private final class DictionaryLockProbeBundleMarker: NSObject {}

enum DictionaryLockProbe {
    static func isLocked(directoryURL: URL) throws -> Bool {
        let canonicalURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let lockURL = canonicalURL.deletingLastPathComponent()
            .appendingPathComponent(".\(canonicalURL.lastPathComponent).lock")
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = [lockURL.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? "Child stderr is not UTF-8."
        guard process.terminationReason == .exit else {
            throw ProbeFailure.terminated(process.terminationStatus)
        }
        switch ProbeStatus(rawValue: process.terminationStatus) {
        case .blocked:
            return true
        case .available:
            return false
        case nil:
            throw ProbeFailure.failed(process.terminationStatus, errorText)
        }
    }

    private static func executableURL() throws -> URL {
        let testBundleURL = Bundle(for: DictionaryLockProbeBundleMarker.self).bundleURL
        #if os(macOS)
        try #require(testBundleURL.pathExtension == "xctest", "Expected the running SwiftPM XCTest bundle")
        let productsURL = testBundleURL.deletingLastPathComponent()
        #else
        let productsURL = testBundleURL
        #endif
        let helperURL = productsURL.appendingPathComponent("DictionaryLockProbe")
        try #require(
            FileManager.default.isExecutableFile(atPath: helperURL.path),
            "Missing the test-only helper in this SwiftPM build: \(helperURL.path)"
        )
        return helperURL
    }

    private enum ProbeFailure: Error {
        case terminated(Int32)
        case failed(Int32, String)
    }

    // The C helper uses distinct exit codes for contention, availability, and errors.
    private enum ProbeStatus: Int32 {
        case blocked = 0
        case available = 1
    }
}
