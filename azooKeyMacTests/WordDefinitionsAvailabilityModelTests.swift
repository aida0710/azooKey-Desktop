import XCTest

@testable import azooKeyMac

@MainActor
final class WordDefinitionsAvailabilityModelTests: XCTestCase {
    func testOnlyConfirmedVisibleCandidatesReceiveAnIconAndOldPagesCannotChangeThem() {
        let fixture = Fixture()
        let first = target(42, word: "語彙")
        let missing = target(7, word: "虚無")
        fixture.model.update(targets: [first, missing])
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
        XCTAssertEqual(fixture.words, [["語彙", "虚無"]])
        fixture.model.update(targets: [first, missing])
        XCTAssertEqual(fixture.words.count, 1)
        fixture.completions[0]([true, false])
        XCTAssertEqual(fixture.model.availableCandidateIndices, [42])
        fixture.model.update(targets: [target(42, word: "別語", generation: 2)])
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
        fixture.completions[0]([true, true])
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
        fixture.completions[1]([false])
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
    }

    func testWordDepthReadingAndUTF8SpellingEachRetireThePreviousResult() {
        let fixture = Fixture()
        let original = target(42, word: "が")
        let alternatives = [target(42, word: "か\u{3099}"), target(42, word: "が", nodeID: 2),
                            target(42, word: "が", reading: "ガ")]
        for next in alternatives {
            fixture.model.update(targets: [original])
            let old = fixture.completions.last
            fixture.model.update(targets: [next])
            old?([true])
            XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
            fixture.completions.last?([true])
            XCTAssertEqual(fixture.model.availableCandidateIndices, [42])
        }
    }

    func testBatchIsBoundedToOneNumberPageAndHidingRejectsTheLateResult() {
        let fixture = Fixture()
        fixture.model.update(targets: (0..<20).map { target($0, word: "語\($0)") })
        XCTAssertEqual(fixture.words.first?.count, 9)
        fixture.model.invalidate()
        fixture.completions[0](Array(repeating: true, count: 9))
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
        XCTAssertEqual(fixture.cancellations, 1)
    }

    func testSelectedWordsTerminalResultTakesPrecedenceOverAnOlderBatch() {
        let fixture = Fixture()
        let word = target(42, word: "橋")
        fixture.model.update(targets: [word])
        fixture.model.record(target: word, found: true)
        fixture.completions[0]([false])
        XCTAssertEqual(fixture.model.availableCandidateIndices, [42])
        fixture.model.record(target: word, found: false)
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
        fixture.model.record(target: target(42, word: "箸"), found: true)
        XCTAssertTrue(fixture.model.availableCandidateIndices.isEmpty)
    }

    private func target(_ index: Int, word: String, generation: UInt = 1, nodeID: Int = 0, reading: String = "") -> WordDefinitionsModel.Target {
        .init(generation: generation, candidateIndex: index, nodeID: nodeID, word: word, reading: reading)
    }

    @MainActor
    private final class Fixture {
        var words: [[String]] = []
        var completions: [WordDefinitionsService.AvailabilityCompletion] = []
        var cancellations = 0
        lazy var model = WordDefinitionsAvailabilityModel(check: { [weak self] words, completion in
            self?.words.append(words)
            self?.completions.append(completion)
        }, cancel: { [weak self] in self?.cancellations += 1 })
    }
}
