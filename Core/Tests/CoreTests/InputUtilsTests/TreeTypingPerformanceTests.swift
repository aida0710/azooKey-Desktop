import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["AZOOKEY_TREE_BENCHMARK"] == "1"))
func treeTypingReportsPerKeyLatency() throws {
    let previousLive = Config.LiveConversion().value
    let previousTree = Config.TreeCandidates().value
    defer {
        Config.LiveConversion().value = previousLive
        Config.TreeCandidates().value = previousTree
    }
    Config.LiveConversion().value = true
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
        containerURL: nil, context: .init(useZenzai: false)
    )
    manager.learningEnabled = false
    let reading = "きょうはがっかいにいこうとおもっていますのでじゅんびします"
    // Discard the first sentence so dictionary loading does not dominate a key.
    let measuredSentences = 7
    let clock = ContinuousClock()
    for showTree in [false, true] {
        Config.TreeCandidates().value = showTree
        var milliseconds: [Double] = []
        for iteration in 0...measuredSentences {
            manager.stopComposition()
            for character in reading {
                let start = clock.now
                manager.insertAtCursorPosition(String(character), inputStyle: .direct)
                if case .composing(let candidates, let selection) = manager.getCurrentCandidateWindow(inputState: .composing) {
                    let presentations = manager.makeCandidatePresentations(candidates)
                    let tree = CandidateTree(entries: presentations.enumerated().map { $0.element.treeEntry(index: $0.offset) })
                    _ = tree.relativeScores(candidateIndex: selection)
                    _ = tree.compactColumns(candidateIndex: selection)
                }
                let elapsed = start.duration(to: clock.now).components
                if iteration > 0 {
                    milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                }
            }
        }
        let sorted = milliseconds.sorted()
        print("TREE_BENCHMARK tree=\(showTree) characters=\(reading.count) samples=\(sorted.count) median_ms=\(sorted[sorted.count / 2]) max_ms=\(sorted.last!)")
        #expect(sorted.count == measuredSentences * reading.count)
    }
}
