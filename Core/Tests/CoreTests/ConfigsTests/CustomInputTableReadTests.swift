@testable import Core
import Foundation
import Testing

@Suite struct CustomInputTableReadTests {
    @Test func missingAndEmptySavedTablesRemainDistinct() throws {
        try withTemporaryFile { file in
            #expect(try CustomInputTableStore.load(from: file, maximumBytes: 0) == nil)
            try Data().write(to: file)
            #expect(try CustomInputTableStore.load(from: file, maximumBytes: 0)?.isEmpty == true)
        }
    }

    @Test func theByteLimitAcceptsTheExactUTF8SizeAndRejectsOneByteLess() throws {
        try withTemporaryFile { file in
            let table = "q\t日本語\n"
            try Data(table.utf8).write(to: file)
            #expect(try CustomInputTableStore.load(from: file, maximumBytes: table.utf8.count) == table)
            #expect(throws: CustomInputTableStore.ReadFailure.tooLarge) {
                try CustomInputTableStore.load(from: file, maximumBytes: table.utf8.count - 1)
            }
        }
    }

    @Test func invalidUTF8AndDirectoriesAreNotTreatedAsAnAbsentTable() throws {
        try withTemporaryFile { file in
            try Data([0xFF]).write(to: file)
            #expect(throws: CustomInputTableStore.ReadFailure.invalidUTF8) {
                try CustomInputTableStore.load(from: file, maximumBytes: 1)
            }
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: CustomInputTableStore.ReadFailure.notRegularFile) {
                try CustomInputTableStore.load(from: file, maximumBytes: 1)
            }
        }
    }

    private func withTemporaryFile(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory.appendingPathComponent("table.tsv"))
    }
}
