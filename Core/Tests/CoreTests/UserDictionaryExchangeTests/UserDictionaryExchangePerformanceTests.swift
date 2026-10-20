@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite("千件の合成辞書")
struct UserDictionaryExchangePerformanceTests {
    @MainActor
    @Test("千件を取込・コンパイルし新しい変換エンジンから登録候補を得る")
    func thousandEntriesRemainUsableAfterImportAndCompilation() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictionaryExchangePerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let entries = Self.entries()
        let content = try UserDictionaryExchange.export(entries)
        let parseStart = DispatchTime.now().uptimeNanoseconds
        let document = try UserDictionaryExchange.parse(content, format: .json)
        let parseEnd = DispatchTime.now().uptimeNanoseconds
        let preview = try UserDictionaryImportPreview.make(document: document, existing: [])
        let previewEnd = DispatchTime.now().uptimeNanoseconds
        #expect(preview.counts.additions == 1_000)
        #expect(preview.counts.excluded == 0)
        let imported = try UserDictionaryImportPreview.applying(preview, to: [])
        let compileStart = DispatchTime.now().uptimeNanoseconds
        try CompiledUserDictionaryStore.rebuild(
            entries: CompiledUserDictionaryStore.entries(from: imported),
            directoryURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: rootURL)
        )
        let compileEnd = DispatchTime.now().uptimeNanoseconds
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let converterEnd = DispatchTime.now().uptimeNanoseconds
        // Three fixed positions cover the beginning, middle and end without timing the entire test suite.
        let sampledOffsets = [0, 499, 999]
        var conversionMilliseconds: [Double] = []
        for offset in sampledOffsets {
            let started = DispatchTime.now().uptimeNanoseconds
            let manager = SegmentsManager(
                kanaKanjiConverter: converter, applicationDirectoryURL: rootURL,
                containerURL: nil, context: .init(useZenzai: false)
            )
            manager.learningEnabled = false
            manager.insertAtCursorPosition(entries[offset].reading, inputStyle: .direct)
            manager.requestSetCandidateWindowState(visible: true)
            switch manager.getCurrentCandidateWindow(inputState: .selecting) {
            case .selecting(let candidates, _), .composing(let candidates, _):
                #expect(candidates.map(\.text).contains(entries[offset].word))
            case .hidden:
                Issue.record("合成辞書の候補が表示されない")
            }
            conversionMilliseconds.append(Self.milliseconds(from: started, to: DispatchTime.now().uptimeNanoseconds))
        }
        // These are observations, not pass thresholds or GUI latency measurements.
        let observation: [String: Any] = [
            "benchmark": "user-dictionary-exchange-1000", "entries": entries.count,
            "format": "json", "bytes": content.count, "learning": false, "zenzai": false,
            "parse_ms": Self.milliseconds(from: parseStart, to: parseEnd),
            "preview_ms": Self.milliseconds(from: parseEnd, to: previewEnd),
            "compile_ms": Self.milliseconds(from: compileStart, to: compileEnd),
            "fresh_converter_initialization_ms": Self.milliseconds(from: compileEnd, to: converterEnd),
            "sampled_offsets": sampledOffsets, "conversion_ms": conversionMilliseconds
        ]
        let measuredJSON = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
        let measuredText = try #require(String(data: measuredJSON, encoding: .utf8))
        print(measuredText)
    }

    private static func entries() -> [Config.UserDictionaryEntry] {
        let digits = Array("あいうえおかきくけこ")
        return (0..<1_000).map { number in
            let suffix = String([digits[number / 100], digits[number / 10 % 10], digits[number % 10]])
            return Config.UserDictionaryEntry(
                word: String(format: "合成語%04d", number),
                reading: "けんしょう" + suffix, hint: "合成fixture"
            )
        }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }
}
