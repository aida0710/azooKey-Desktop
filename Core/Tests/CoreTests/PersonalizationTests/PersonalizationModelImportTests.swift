@testable import Core
import Foundation
import Testing

private final class ModelDirectories {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("personalization-\(UUID().uuidString)")
    var source: URL { root.appendingPathComponent("tuner-output") }
    var destination: URL { root.appendingPathComponent("data/personalization") }
    var current: URL { destination.appendingPathComponent("current") }

    init(contents: (String) -> Data = { Data("We love Marisa.\0\($0)".utf8) }) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in PersonalizationModelImport.fileNames {
            try contents(name).write(to: source.appendingPathComponent(name))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func currentFiles() throws -> [String: Data] {
        let directory = try #require(PersonalizationModelImport.currentModelDirectory(in: destination))
        return try Dictionary(uniqueKeysWithValues: PersonalizationModelImport.fileNames.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }
}

@Test func importCopiesAllFourFilesBehindTheCurrentLink() throws {
    let directories = try ModelDirectories()
    #expect(PersonalizationModelImport.currentModelDirectory(in: directories.destination) == nil)
    let stage = try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    #expect(PersonalizationModelImport.currentModelDirectory(in: directories.destination)?.lastPathComponent == stage.lastPathComponent)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: directories.current.path) == stage.lastPathComponent)
    for (name, content) in try directories.currentFiles() {
        #expect(content == Data("We love Marisa.\0\(name)".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: stage.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    // The Tuner output stays untouched.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directories.source.path).sorted() == PersonalizationModelImport.fileNames)
}

@Test func reimportReplacesTheLinkAndKeepsThePreviousModelForReaders() throws {
    let directories = try ModelDirectories()
    let first = try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    let replacement = Data("We love Marisa.\0replacement".utf8)
    try replacement.write(to: directories.source.appendingPathComponent("lm_c_abc.marisa"))
    let second = try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    #expect(first != second)
    #expect(try directories.currentFiles()["lm_c_abc.marisa"] == replacement)
    #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("lm_c_abc.marisa").path))
}

@Test func invalidFilesNameTheFileAndLeaveTheCurrentModel() throws {
    let directories = try ModelDirectories()
    try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    let before = try directories.currentFiles()
    let modelsBefore = try FileManager.default.contentsOfDirectory(atPath: directories.destination.path).sorted()

    try Data("not a marisa trie file".utf8).write(to: directories.source.appendingPathComponent("lm_r_xbx.marisa"))
    #expect(throws: PersonalizationModelImport.Failure(reason: .notMarisa, file: "lm_r_xbx.marisa")) {
        try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    }
    try Data("We love Marisa.\0".utf8).write(to: directories.source.appendingPathComponent("lm_r_xbx.marisa"))
    #expect(throws: PersonalizationModelImport.Failure(reason: .invalidFile, file: "lm_r_xbx.marisa")) {
        try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    }
    try Data("We love Marisa.\0lm_r_xbx.marisa".utf8).write(to: directories.source.appendingPathComponent("lm_r_xbx.marisa"))
    try FileManager.default.removeItem(at: directories.source.appendingPathComponent("lm_u_xbc.marisa"))
    try FileManager.default.createDirectory(at: directories.source.appendingPathComponent("lm_u_xbc.marisa"), withIntermediateDirectories: false)
    #expect(throws: PersonalizationModelImport.Failure(reason: .invalidFile, file: "lm_u_xbc.marisa")) {
        try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    }
    #expect(try directories.currentFiles() == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directories.destination.path).sorted() == modelsBefore)
}

@Test func validationFailureCreatesNoDestination() throws {
    let directories = try ModelDirectories()
    try FileManager.default.removeItem(at: directories.source.appendingPathComponent("lm_c_abc.marisa"))
    #expect(throws: PersonalizationModelImport.Failure(reason: .invalidFile, file: "lm_c_abc.marisa")) {
        try PersonalizationModelImport.importModel(from: directories.source, into: directories.destination)
    }
    #expect(!FileManager.default.fileExists(atPath: directories.destination.path))
}
