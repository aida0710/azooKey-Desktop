import Foundation
import XCTest

@testable import azooKeyMac

@MainActor
final class WordDefinitionsModelTests: XCTestCase {
    func testRepeatedRenderingKeepsOneSearchAndDoesNotAppendTheReadingToTheWord() {
        let fixture = Fixture()
        let target = fixture.target(word: "人気", reading: "ヒトケ")
        fixture.model.update(target: target)
        fixture.model.update(target: target)
        XCTAssertEqual(fixture.words, ["人気"])
        XCTAssertEqual(fixture.model.result, .loading)
        fixture.completions[0]("説明の全文")
        XCTAssertEqual(fixture.model.result, .definition("説明の全文"))
        XCTAssertEqual(fixture.model.target?.reading, "ヒトケ")
    }

    func testReturningToTheSameWordRejectsTheFirstSearchResult() {
        let fixture = Fixture()
        fixture.model.update(target: fixture.target(word: "橋"))
        fixture.model.update(target: fixture.target(word: "箸"))
        fixture.model.update(target: fixture.target(word: "橋"))
        fixture.completions[0]("古い橋の説明")
        fixture.completions[1]("箸の説明")
        XCTAssertEqual(fixture.model.result, .loading)
        fixture.completions[2]("現在の橋の説明")
        XCTAssertEqual(fixture.model.result, .definition("現在の橋の説明"))
    }

    func testNewGenerationCandidateAndReadingInvalidateOldResults() {
        let fixture = Fixture()
        let targets = [
            fixture.target(word: "生", generation: 1),
            fixture.target(word: "生", generation: 2),
            fixture.target(word: "生", generation: 2, candidateIndex: 42),
            fixture.target(word: "生", reading: "セイ", generation: 2, candidateIndex: 42)
        ]
        targets.forEach { fixture.model.update(target: $0) }
        for completion in fixture.completions.dropLast() { completion("古い説明") }
        XCTAssertEqual(fixture.model.result, .loading)
        fixture.completions.last?("現在の説明")
        XCTAssertEqual(fixture.model.result, .definition("現在の説明"))
        XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
        XCTAssertEqual(fixture.model.target?.reading, "セイ")
    }

    func testHidingDiscardsRunningAndWaitingResultsBeforeTheSameWordIsShownAgain() {
        let fixture = Fixture()
        let target = fixture.target(word: "辞典")
        fixture.model.update(target: target)
        fixture.model.invalidate()
        fixture.completions[0]("閉じた後の説明")
        XCTAssertNil(fixture.model.target)
        XCTAssertNil(fixture.model.result)
        XCTAssertEqual(fixture.cancellations, 1)
        fixture.model.update(target: target)
        fixture.completions[0]("再表示前の古い説明")
        XCTAssertEqual(fixture.model.result, .loading)
        fixture.completions[1]("再表示後の説明")
        XCTAssertEqual(fixture.model.result, .definition("再表示後の説明"))
    }

    func testNilEmptyAndWhitespaceDoNotInventDefinitionsOrDiagnoseMissingDictionaries() {
        let fixture = Fixture()
        for (index, definition) in [nil, "", " \n\t"].enumerated() {
            fixture.model.update(target: fixture.target(word: "未収録の合成語", generation: UInt(index)))
            fixture.completions[index](definition)
            XCTAssertEqual(fixture.model.result, .notFound)
        }
    }

    func testChangingOnlyTheReadingRejectsTheOldReadingPresentation() {
        let fixture = Fixture()
        fixture.model.update(target: fixture.target(word: "人気", reading: "ニンキ"))
        fixture.model.update(target: fixture.target(word: "人気", reading: "ヒトケ"))
        fixture.completions[0]("最初の説明")
        XCTAssertEqual(fixture.model.result, .loading)
        fixture.completions[1]("同表記の説明")
        XCTAssertEqual(fixture.model.result, .definition("同表記の説明"))
        XCTAssertEqual(fixture.words, ["人気", "人気"])
    }

    func testCanonicallyEquivalentWordsKeepTheirActualBytes() {
        let fixture = Fixture()
        fixture.model.update(target: fixture.target(word: "é"))
        fixture.model.update(target: fixture.target(word: "e\u{301}"))
        XCTAssertEqual(fixture.words.map { Array($0.utf8) }, [Array("é".utf8), Array("e\u{301}".utf8)])
        fixture.completions[0]("古い表記の説明")
        XCTAssertEqual(fixture.model.result, .loading)
    }

    @MainActor
    private final class Fixture {
        var words: [String] = []
        var completions: [WordDefinitionsService.Completion] = []
        var cancellations = 0
        lazy var model = WordDefinitionsModel(search: { [weak self] in
            self?.words.append($0)
            self?.completions.append($1)
        }, cancelPending: { [weak self] in self?.cancellations += 1 })

        func target(word: String, reading: String = "", generation: UInt = 0, candidateIndex: Int = 7) -> WordDefinitionsModel.Target {
            .init(generation: generation, candidateIndex: candidateIndex, word: word, reading: reading)
        }
    }
}
