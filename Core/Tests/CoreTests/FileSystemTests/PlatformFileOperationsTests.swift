import Foundation
import Testing

@testable import Core

#if os(Linux)
@Suite("リンクをたどらないファイル種別の判定")
struct PlatformFileOperationsTests {
    @Test("通常のファイルだけを受け入れディレクトリとリンクは拒否する")
    func onlyRegularFilesAreAcceptedWithoutFollowingLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-file-type-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.json")
        let link = directory.appendingPathComponent("link.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try PlatformFileOperations.isRegularFileWithoutFollowingLinks(file))
        #expect(try !PlatformFileOperations.isRegularFileWithoutFollowingLinks(directory))
        #expect(try !PlatformFileOperations.isRegularFileWithoutFollowingLinks(link))
        try FileManager.default.removeItem(at: file)
        #expect(try !PlatformFileOperations.isRegularFileWithoutFollowingLinks(link))
        #expect(throws: (any Error).self) {
            try PlatformFileOperations.isRegularFileWithoutFollowingLinks(file)
        }
    }
}
#endif
