@testable import DesktopBridge
import Foundation
import Testing

struct DesktopWorkerJSONLReaderTests {
    @Test func exactLimitAndFinalFrameWithoutNewlineRemainIntact() throws {
        try withReader(Data("abcd\nef\nlast".utf8), limit: 4) { (reader: inout DesktopWorkerJSONLReader) throws in
            #expect(try content(reader.next()) == Data("abcd".utf8))
            #expect(try content(reader.next()) == Data("ef".utf8))
            #expect(try content(reader.next()) == Data("last".utf8))
            #expect(try reader.next() == nil)
        }
    }

    @Test func oversizedFrameAcrossChunksEmitsOneFailureAndPreservesTheFollowingFrame() throws {
        var bytes = Data(repeating: 0x61, count: 131_072)
        bytes.append(contentsOf: [0x0a, 0xff, 0x0a])
        try withReader(bytes, limit: 65_536) { (reader: inout DesktopWorkerJSONLReader) throws in
            guard case .oversized = try reader.next() else {
                Issue.record("oversized frame was accepted")
                return
            }
            #expect(try content(reader.next()) == Data([0xff]))
            #expect(try reader.next() == nil)
        }
    }

    @Test func emptyLinesAndOversizedUnterminatedInputEachProduceTheirOwnFrame() throws {
        try withReader(Data("\n\nabcde".utf8), limit: 4) { (reader: inout DesktopWorkerJSONLReader) throws in
            #expect(try content(reader.next()) == Data())
            #expect(try content(reader.next()) == Data())
            guard case .oversized = try reader.next() else {
                Issue.record("oversized final frame was accepted")
                return
            }
            #expect(try reader.next() == nil)
        }
    }

    private func content(_ frame: DesktopWorkerJSONLReader.Frame?) -> Data? {
        if case .json(let bytes) = frame {
            return bytes
        }
        return nil
    }

    private func withReader(
        _ bytes: Data, limit: Int, check: (inout DesktopWorkerJSONLReader) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var reader = DesktopWorkerJSONLReader(descriptor: file.fileDescriptor, limit: limit)
        try check(&reader)
    }
}
