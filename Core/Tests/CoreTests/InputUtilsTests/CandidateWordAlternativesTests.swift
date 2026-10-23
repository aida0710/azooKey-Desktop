@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
struct CandidateWordAlternativesTests {
    private func withManager(_ test: (SegmentsManager) throws -> Void) rethrows {
        let previousLive = Config.LiveConversion().value
        let previousTree = Config.TreeCandidates().value
        defer {
            Config.LiveConversion().value = previousLive
            Config.TreeCandidates().value = previousTree
        }
        Config.LiveConversion().value = true
        Config.TreeCandidates().value = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
            containerURL: nil, context: .init(useZenzai: false)
        )
        manager.learningEnabled = false
        try test(manager)
    }

    @Test func laterWordsHaveExactReadingAlternativesThatCommitOnlyTheEditedWord() throws {
        try withManager { manager in
            manager.insertAtCursorPosition("kyouhagakkainiikoutoomotteimasu", inputStyle: .roman2kana)
            guard case .composing(let candidates, let selection) = manager.getCurrentCandidateWindow(inputState: .composing) else {
                Issue.record("Expected a live sentence")
                return
            }
            let index = try #require(selection)
            let presentations = manager.makeCandidatePresentations(candidates)
            let tree = CandidateTree(entries: presentations.enumerated().map { $0.element.treeEntry(index: $0.offset) })
            let path = try #require(tree.paths[index])
            let columns = tree.compactColumns(candidateIndex: index)
            #expect(candidates[index].text == "今日は学会に行こうと思っています")
            for depth in path.indices.dropFirst() {
                let original = tree.nodes[path[depth]]
                let alternative = try #require(columns[depth].dropFirst().first {
                    tree.nodes[$0].parentID == original.parentID && tree.nodes[$0].token.reading == original.token.reading
                })
                let alternativeIndex = try #require(tree.preferredCandidate(at: alternative, preserving: index))
                let alternativePath = try #require(tree.paths[alternativeIndex])
                #expect(alternativePath.count == path.count)
                for position in path.indices where position != depth {
                    #expect(tree.nodes[alternativePath[position]].token == tree.nodes[path[position]].token)
                }
            }
            let edited = try #require(presentations.first {
                $0.candidate.text == "今日は学界に行こうと思っています"
            })
            let editedIndex = try #require(candidates.firstIndex(of: edited.candidate))
            manager.requestSelectingRow(editedIndex)
            #expect(manager.selectedCandidate?.text == "今日は学界に行こうと思っています")
            #expect(edited.commitScope?.remainingReading.isEmpty == true)
            manager.prefixCandidateCommited(edited.candidate, leftSideContext: "")
            #expect(manager.isEmpty)
        }
    }

    @Test func selectingAnEditedSentenceAllowsAnotherWordEditWithoutRenumberingCandidates() throws {
        try withManager { manager in
            manager.insertAtCursorPosition("kyouhagakkainiikoutoomotteimasu", inputStyle: .roman2kana)
            guard case .composing(let original, _) = manager.getCurrentCandidateWindow(inputState: .composing) else {
                Issue.record("Expected a live sentence")
                return
            }
            let index = try #require(original.firstIndex { $0.text == "今日は学界に行こうと思っています" })
            manager.requestSelectingRow(index)
            guard case .selecting(let expanded, let selection) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                Issue.record("Expected the selected sentence")
                return
            }
            #expect(selection == index)
            #expect(Array(expanded.prefix(original.count)) == original)
            let presentations = manager.makeCandidatePresentations(expanded)
            let tree = CandidateTree(entries: presentations.enumerated().map { $0.element.treeEntry(index: $0.offset) })
            let path = try #require(tree.paths[index])
            let last = try #require(path.last)
            #expect(tree.compactColumns(candidateIndex: index).last!.contains {
                $0 != last && tree.nodes[$0].parentID == tree.nodes[last].parentID
            })
            #expect(expanded.filter { !$0.value.isFinite }.count <= CandidateWordAlternatives.maximumCandidates)
        }
    }

    @Test func disablingTheTreeSkipsWordCandidatesAndStartingNewInputDropsOldEdits() throws {
        try withManager { manager in
            for enabled in [false, true, false] {
                Config.TreeCandidates().value = enabled
                manager.stopComposition()
                manager.insertAtCursorPosition("がっかいにいこう", inputStyle: .direct)
                manager.update(requestRichCandidates: false)
                guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                    Issue.record("Expected conversion candidates")
                    return
                }
                #expect(candidates.contains { !$0.value.isFinite } == enabled)
            }
        }
    }

    @Test func choosingTheKanaSentenceStillOffersEditsForItsLaterWords() throws {
        try withManager { manager in
            let reading = "きょうはがっかいにいこうとおもっています"
            manager.insertAtCursorPosition(reading, inputStyle: .direct)
            guard case .composing(let original, _) = manager.getCurrentCandidateWindow(inputState: .composing) else {
                Issue.record("Expected a live sentence")
                return
            }
            let index = try #require(original.firstIndex { $0.text == reading && $0.data.count == 1 })
            manager.requestSelectingRow(index)
            guard case .selecting(let expanded, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
                Issue.record("Expected the kana sentence")
                return
            }
            let edited = try #require(expanded.first { $0.text == "きょうは学界にいこうとおもっています" })
            #expect(edited.composingCount == original[index].composingCount)
            let presentations = manager.makeCandidatePresentations(expanded)
            let tree = CandidateTree(entries: presentations.enumerated().map { $0.element.treeEntry(index: $0.offset) })
            #expect(tree.compactColumns(candidateIndex: index)[1].contains { tree.nodes[$0].token.text == "学界" })
            manager.prefixCandidateCommited(edited, leftSideContext: "")
            #expect(manager.isEmpty)
        }
    }

    @Test func longSentencesAndRepeatedSelectionsStayWithinTheCandidateBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let word = DicdataElement(word: "学会", ruby: "ガッカイ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)
        let elements = Array(repeating: word, count: CandidateWordAlternatives.maximumWords + 4)
        let candidate = Candidate(text: elements.map(\.word).joined(), value: -10,
                                  composingCount: .surfaceCount(elements.map(\.ruby).joined().count), lastMid: word.mid, data: elements)
        let generator = CandidateWordAlternatives()
        let options = ConvertRequestOptions(
            requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            learningType: .nothing, memoryDirectoryURL: directory, sharedContainerURL: directory,
            textReplacer: .empty, specialCandidateProviders: [], metadata: nil
        )
        let request = CandidateWordAlternatives.Request(converter: .withDefaultDictionary(), options: options)
        generator.append(for: candidate, existing: [candidate], request: request)
        #expect(generator.alternatives.count == CandidateWordAlternatives.maximumWords * CandidateWordAlternatives.alternativesPerWord)
        for alternative in generator.alternatives {
            #expect(Array(alternative.tokens.suffix(4)) == Array(repeating: .init(text: "学会", reading: "ガッカイ"), count: 4))
            #expect(alternative.candidate.composingCount == candidate.composingCount)
            #expect(!alternative.candidate.value.isFinite)
        }
        let firstRound = generator.alternatives
        for alternative in firstRound {
            generator.append(for: alternative.candidate, existing: [candidate] + generator.alternatives.map(\.candidate), request: request)
        }
        #expect(generator.alternatives.count == CandidateWordAlternatives.maximumCandidates)
        #expect(Array(generator.alternatives.prefix(firstRound.count)).map(\.candidate) == firstRound.map(\.candidate))
        generator.reset()
        #expect(generator.alternatives.isEmpty)
    }
}
