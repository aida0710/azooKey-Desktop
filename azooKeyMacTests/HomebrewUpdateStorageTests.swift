import Foundation
import XCTest

@testable import azooKeyMac

@MainActor
final class HomebrewUpdateStorageTests: XCTestCase {
    func testPreparingCreatesOnlyPrivateStructuredDataAndRestoresTheSameJob() throws {
        try withStorage { storage, root in
            let request = makeRequest(bundlePath: "/Applications/azooKey $(literal) ' Tree.app")
            let job = try storage.prepare(request)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.directory.path), ["request.plist"])
            XCTAssertEqual(try permissions(job.directory), 0o700)
            XCTAssertEqual(try permissions(job.directory.appendingPathComponent("request.plist")), 0o600)
            XCTAssertEqual(try permissions(root.appendingPathComponent("latest.plist")), 0o600)
            let latest = try Data(contentsOf: root.appendingPathComponent("latest.plist"))
            let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: latest, options: .init(), format: nil) as? [String: String])
            XCTAssertEqual(fields, ["jobID": request.jobID])
            XCTAssertEqual(try storage.restore()?.request, request)
            XCTAssertNil(try storage.readStatus(for: job))
            try storage.recordFailure(.launchFailed, for: job)
            XCTAssertEqual(try storage.readFailure(for: job), .launchFailed)
        }
    }

    func testPreparingTheSameJobAgainDoesNotReplaceItsRequest() throws {
        try withStorage { storage, _ in
            let request = makeRequest()
            _ = try storage.prepare(request)
            XCTAssertThrowsError(try storage.prepare(request))
            XCTAssertEqual(try storage.restore()?.request, request)
        }
    }

    func testStatusSymlinksPublicFilesAndOversizedDocumentsAreRejected() throws {
        try withStorage { storage, root in
            let job = try storage.prepare(makeRequest())
            let status = job.directory.appendingPathComponent("status.json")
            let external = root.appendingPathComponent("external.json")
            try Data("{}".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: status, withDestinationURL: external)
            XCTAssertThrowsError(try storage.readStatus(for: job))
            try FileManager.default.removeItem(at: status)
            try Data("{}".utf8).write(to: status)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: status.path)
            XCTAssertThrowsError(try storage.readStatus(for: job))
            try Data(repeating: 65, count: HomebrewUpdateStorage.maximumDocumentBytes + 1).write(to: status)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: status.path)
            XCTAssertThrowsError(try storage.readStatus(for: job))
        }
    }

    func testLatestReferenceCannotEscapeTheJobRoot() throws {
        try withStorage { storage, root in
            _ = try storage.prepare(makeRequest())
            let data = try PropertyListSerialization.data(fromPropertyList: ["jobID": "../../outside"], format: .xml, options: 0)
            try data.write(to: root.appendingPathComponent("latest.plist"))
            XCTAssertThrowsError(try storage.restore())
        }
    }

    func testAnExistingPublicJobRootIsNotSilentlyAdopted() throws {
        try withStorage { storage, root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            XCTAssertThrowsError(try storage.prepare(makeRequest()))
            XCTAssertEqual(try permissions(root), 0o755)
        }
    }

    private func withStorage(_ operation: (HomebrewUpdateStorage, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("HomebrewUpdates", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(HomebrewUpdateStorage(root: root), root)
    }

    private func makeRequest(bundlePath: String = "/Applications/azooKeyMac.app") -> HomebrewUpdateRequest {
        HomebrewUpdateRequest(jobID: UUID().uuidString, bundlePath: bundlePath, bundleVersion: "0.1.2", parentPID: 100, language: "en")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
