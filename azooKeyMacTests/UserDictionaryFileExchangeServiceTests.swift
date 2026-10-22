import Core
import Foundation
import XCTest

@testable import azooKeyMac

final class UserDictionaryFileExchangeServiceTests: XCTestCase {
    func testJSONFileRoundTripPreservesRawReadingWordsAndHints() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let characters = directory.appendingPathComponent("charID.chid")
        try "ニホンゴ".write(to: characters, atomically: true, encoding: .utf8)
        let entries: [Config.UserDictionaryEntry] = [
            .init(word: "日本語👩‍💻", reading: "にほんご", hint: "タブ\tと改行\nを保持"),
            .init(word: "別の語", reading: "ニホンゴ")
        ]
        let destination = directory.appendingPathComponent("backup.json")
        try Data("old file".utf8).write(to: destination)
        try await UserDictionaryFileExchangeService.export(entries, to: destination)
        let preview = try await UserDictionaryFileExchangeService.preview(
            from: destination, options: .init(format: .json, encoding: .automatic), existing: [], charIDFileURL: characters
        )
        let restored = try UserDictionaryImportPreview.applying(preview, to: [])
        XCTAssertEqual(try UserDictionaryExchange.export(restored), try UserDictionaryExchange.export(entries))
        XCTAssertNotEqual(restored.map(\.id), entries.map(\.id))
    }

    func testAnUnreadableImportFailsWithoutCreatingAnOutputFile() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await UserDictionaryFileExchangeService.preview(
                from: missing, options: .init(format: .json, encoding: .automatic), existing: []
            )
            XCTFail("An unreadable file must report an import failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }
}
