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
