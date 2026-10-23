import CoreServices
import Foundation
import XCTest

@testable import azooKeyMac

@MainActor
final class WordDefinitionsServiceTests: XCTestCase {
    // Completion and explicit gates, rather than sleeps, determine the worker ordering.
    private let completionTimeout: TimeInterval = 5

    func testSynchronousDictionarySearchRunsOffTheInputThreadAndReturnsOnMainActor() async {
        let completed = expectation(description: "background dictionary result")
        let service = WordDefinitionsService { word in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(word, "合成語")
            return "合成した説明"
        }
        service.search(word: "合成語") { definition in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(definition, "合成した説明")
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: completionTimeout)
    }

    func testOnlyTheLatestWaitingWordRunsAfterAnOlderLookupFinishes() async {
        let started = expectation(description: "first lookup started")
        let completed = expectation(description: "latest lookup returned")
        let probe = LookupProbe(started: started)
        let service = WordDefinitionsService(lookup: probe.lookup)
        service.search(word: "最初") { _ in XCTFail("The old result must be discarded") }
        await fulfillment(of: [started], timeout: completionTimeout)
        service.search(word: "途中") { _ in XCTFail("The superseded waiting word must not run") }
        service.search(word: "最後") { definition in
            XCTAssertEqual(definition, "最後の説明")
            completed.fulfill()
        }
        probe.releaseFirst()
        await fulfillment(of: [completed], timeout: completionTimeout)
        XCTAssertEqual(probe.words, ["最初", "最後"])
    }

    func testDictionaryRangesUseUTF16IncludingSurrogatesAndCombiningCharacters() {
        let range = WordDefinitionsService.queryRange(for: "😀か\u{3099}")
        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 4)
        XCTAssertEqual(WordDefinitionsService.queryRange(for: "").length, 0)
    }

    func testAvailabilityChecksAtMostNineWordsOffTheInputThreadAndRequiresANonemptyDefinition() async {
        let completed = expectation(description: "bounded availability")
        let words = ["語彙", "虚無", "空白", "未収録", "四", "五", "六", "七", "八", "超過"]
        let service = WordDefinitionsService { word in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotEqual(word, "超過")
            switch word {
            case "虚無", "未収録": return nil
            case "空白": return " \n\t"
            default: return "実在する説明"
            }
        }
        service.checkAvailability(words: words) { found in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(found, [true, false, false, false, true, true, true, true, true])
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: completionTimeout)
    }

    func testSelectedLookupRunsBeforeTheRestOfTheNewestAvailabilityPage() async {
        let started = expectation(description: "old page started")
        let selected = expectation(description: "selected word completed")
        let completed = expectation(description: "new page completed")
        let probe = LookupProbe(started: started)
        let service = WordDefinitionsService(lookup: probe.lookup)
        service.checkAvailability(words: ["最初", "破棄する旧候補"]) { _ in XCTFail("Old page must not complete") }
        await fulfillment(of: [started], timeout: completionTimeout)
        service.checkAvailability(words: ["新候補"]) { found in
            XCTAssertEqual(found, [true])
            completed.fulfill()
        }
        service.search(word: "選択中") { definition in
            XCTAssertEqual(definition, "選択中の説明")
            selected.fulfill()
        }
        probe.releaseFirst()
        await fulfillment(of: [selected, completed], timeout: completionTimeout)
        XCTAssertEqual(probe.words, ["最初", "選択中", "新候補"])
    }

    func testCancelingAvailabilityDoesNotCancelTheSelectedWordOrRunMoreOldCandidates() async {
        let started = expectation(description: "lookup started")
        let completed = expectation(description: "selected lookup completed")
        let probe = LookupProbe(started: started)
        let service = WordDefinitionsService(lookup: probe.lookup)
        service.checkAvailability(words: ["最初", "破棄する候補"]) { _ in XCTFail("Hidden page must not complete") }
        await fulfillment(of: [started], timeout: completionTimeout)
        service.cancelAvailability()
        service.search(word: "選択中") { _ in completed.fulfill() }
        probe.releaseFirst()
        await fulfillment(of: [completed], timeout: completionTimeout)
        XCTAssertEqual(probe.words, ["最初", "選択中"])
    }

    func testAvailabilityCacheReusesFoundAndMissingWordsButPreservesUTF8Spelling() async {
        let probe = CachedLookupProbe()
        let service = WordDefinitionsService(lookup: probe.lookup)
        for _ in 0..<2 {
            let completed = expectation(description: "cached page")
            service.checkAvailability(words: ["が", "か\u{3099}", "未収録", ""]) { found in
                XCTAssertEqual(found, [true, false, false, false])
                completed.fulfill()
            }
            await fulfillment(of: [completed], timeout: completionTimeout)
        }
        XCTAssertEqual(probe.words.map { Array($0.utf8) }, ["が", "か\u{3099}", "未収録"].map { Array($0.utf8) })
    }

    func testAvailabilityCacheEvictsOldWordsInsteadOfGrowingAcrossPages() async {
        let probe = CachedLookupProbe()
        let service = WordDefinitionsService(lookup: probe.lookup)
        for start in stride(from: 0, to: 135, by: 9) {
            let completed = expectation(description: "page \(start)")
            service.checkAvailability(words: (start..<(start + 9)).map { "語\($0)" }) { _ in completed.fulfill() }
            await fulfillment(of: [completed], timeout: completionTimeout)
        }
        let completed = expectation(description: "evicted word queried again")
        service.checkAvailability(words: ["語0"]) { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: completionTimeout)
        XCTAssertEqual(probe.words.filter { $0 == "語0" }.count, 2)
        XCTAssertEqual(probe.words.count, 136)
    }

    private final class CachedLookupProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var searchedWords: [String] = []
        var words: [String] {
            lock.lock()
            defer { lock.unlock() }
            return searchedWords
        }
        func lookup(_ word: String) -> String? {
            lock.lock()
            searchedWords.append(word)
            lock.unlock()
            return Array(word.utf8) == Array("が".utf8) || word.hasPrefix("語") ? "実在する説明" : nil
        }
    }

    private final class LookupProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let started: XCTestExpectation
        private var searchedWords: [String] = []
        var words: [String] {
            lock.lock()
            defer { lock.unlock() }
            return searchedWords
        }

        init(started: XCTestExpectation) { self.started = started }
        func releaseFirst() { gate.signal() }

        func lookup(_ word: String) -> String? {
            lock.lock()
            searchedWords.append(word)
            lock.unlock()
            if word == "最初" {
                started.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else {
                    XCTFail("The test did not release the lookup")
                    return nil
                }
            }
            return word + "の説明"
        }
    }
}
