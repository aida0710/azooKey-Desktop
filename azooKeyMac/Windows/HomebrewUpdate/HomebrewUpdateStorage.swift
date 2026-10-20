import Darwin
import Foundation

@MainActor
protocol HomebrewUpdateStoring {
    func prepare(_ request: HomebrewUpdateRequest) throws -> HomebrewUpdateJob
    func restore() throws -> HomebrewUpdateJob?
    func readStatus(for job: HomebrewUpdateJob) throws -> Data?
    func hasStarted(_ job: HomebrewUpdateJob) throws -> Bool
    func readFailure(for job: HomebrewUpdateJob) throws -> HomebrewUpdateFailure?
    func recordFailure(_ failure: HomebrewUpdateFailure, for job: HomebrewUpdateJob) throws
}

/// Stores data only. The executable helper is a signed resource of the app.
@MainActor
final class HomebrewUpdateStorage: HomebrewUpdateStoring {
    // A status contains six short fields; a bound also covers corrupt local files.
    static let maximumDocumentBytes = 16_384
    private let root: URL
    private let fileManager: FileManager

    private struct LatestJob: Codable { let jobID: String }
    private struct NativeResult: Codable {
        let jobID: String
        let failure: HomebrewUpdateFailure
    }
    private enum StorageError: Error { case invalidFile, invalidDirectory, invalidRequest }

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func prepare(_ request: HomebrewUpdateRequest) throws -> HomebrewUpdateJob {
        guard request.isValid else {
            throw StorageError.invalidRequest
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateDirectory(root)
        let directory = root.appendingPathComponent(request.jobID, isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw StorageError.invalidDirectory
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try validateDirectory(directory)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try writePrivate(encoder.encode(request), to: directory.appendingPathComponent("request.plist"))
        try writePrivate(encoder.encode(LatestJob(jobID: request.jobID)), to: root.appendingPathComponent("latest.plist"))
        return HomebrewUpdateJob(request: request, directory: directory, createdAt: Date())
    }

    func restore() throws -> HomebrewUpdateJob? {
        guard fileManager.fileExists(atPath: root.path) else {
            return nil
        }
        try validateDirectory(root)
        guard let latest = try readPrivate(root.appendingPathComponent("latest.plist")) else {
            return nil
        }
        let reference = try PropertyListDecoder().decode(LatestJob.self, from: latest)
        guard reference.jobID.count == 36, UUID(uuidString: reference.jobID) != nil else {
            throw StorageError.invalidRequest
        }
        let directory = root.appendingPathComponent(reference.jobID, isDirectory: true)
        try validateDirectory(directory)
        guard let requestData = try readPrivate(directory.appendingPathComponent("request.plist")) else {
            throw StorageError.invalidRequest
        }
        let request = try PropertyListDecoder().decode(HomebrewUpdateRequest.self, from: requestData)
        guard request.isValid, request.jobID == reference.jobID else {
            throw StorageError.invalidRequest
        }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard let createdAt = attributes[.creationDate] as? Date else {
            throw StorageError.invalidDirectory
        }
        return HomebrewUpdateJob(request: request, directory: directory, createdAt: createdAt)
    }

    func readStatus(for job: HomebrewUpdateJob) throws -> Data? {
        try validateDirectory(job.directory)
        return try readPrivate(job.directory.appendingPathComponent("status.json"))
    }

    func hasStarted(_ job: HomebrewUpdateJob) throws -> Bool {
        try validateDirectory(job.directory)
        let started = job.directory.appendingPathComponent(".started", isDirectory: true)
        guard fileManager.fileExists(atPath: started.path) else {
            return false
        }
        try validateDirectory(started)
        return true
    }

    func readFailure(for job: HomebrewUpdateJob) throws -> HomebrewUpdateFailure? {
        guard let data = try readPrivate(job.directory.appendingPathComponent("native-result.plist")) else {
            return nil
        }
        let result = try PropertyListDecoder().decode(NativeResult.self, from: data)
        guard result.jobID == job.request.jobID else {
            throw StorageError.invalidRequest
        }
        return result.failure
    }

    func recordFailure(_ failure: HomebrewUpdateFailure, for job: HomebrewUpdateJob) throws {
        try validateDirectory(job.directory)
        let result = NativeResult(jobID: job.request.jobID, failure: failure)
        try writePrivate(PropertyListEncoder().encode(result), to: job.directory.appendingPathComponent("native-result.plist"))
    }

    private func validateDirectory(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw StorageError.invalidDirectory
        }
    }

    private func readPrivate(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw StorageError.invalidFile
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: Self.maximumDocumentBytes + 1) ?? Data()
        guard data.count <= Self.maximumDocumentBytes else {
            throw StorageError.invalidFile
        }
        return data
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        // Terminal must see a complete request/reference when it starts reading.
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
