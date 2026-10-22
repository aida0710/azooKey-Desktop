import Core
import Foundation
import XCTest

@testable import azooKeyMac

/// Earlier versions kept the instruction history in the preferences. Pinned
/// instructions and their shortcuts must survive the move to Core's file.
final class PreferencesPromptHistoryTests: XCTestCase {
    private let key = Config.PromptHistory.key
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = Config.userDefaults.object(forKey: key)
    }

    override func tearDown() {
        Config.set(savedValue, forKey: key)
        super.tearDown()
    }

    func testItemsOfEarlierVersionsKeepTheirPinsShortcutsAndTimes() {
        let usedAt = Date(timeIntervalSince1970: 1_800_000_000)
        // The format those versions wrote: a JSONEncoder date counts seconds since 2001.
        let saved = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "prompt": "敬語に直す", "isPinned": true, "#
            + #""lastUsed": \#(usedAt.timeIntervalSinceReferenceDate), "shortcut": {"key": "e", "modifiers": 6}}, "#
            + #"{"prompt": "英訳"}]"#
        Config.set(Data(saved.utf8), forKey: key)
        let items = PreferencesPromptHistory.items()
        XCTAssertEqual(items.map(\.prompt), ["敬語に直す", "英訳"])
        XCTAssertEqual(items.map(\.pinned), [true, false])
        XCTAssertEqual(items.first?.lastUsed, usedAt.timeIntervalSince1970)
        XCTAssertEqual(items.first?.shortcut, KeyboardShortcut(key: "e", modifiers: [.control, .option]))
    }

    func testTheOldestFormatKeepsTheInstructionsInTheirOrder() {
        Config.set(Data(#"["新しい指示", "古い指示"]"#.utf8), forKey: key)
        let items = PreferencesPromptHistory.items()
        XCTAssertEqual(items.map(\.prompt), ["新しい指示", "古い指示"])
        XCTAssertTrue(items.allSatisfy { !$0.pinned && $0.shortcut == nil })
    }

    func testAHistoryKeptAsTextIsRead() {
        Config.set(#"[{"prompt": "敬語に直す", "isPinned": true}]"#, forKey: key)
        XCTAssertEqual(PreferencesPromptHistory.items().map(\.prompt), ["敬語に直す"])
    }

    func testAnUnreadableValueImportsNothing() {
        Config.set(Data("{".utf8), forKey: key)
        XCTAssertTrue(PreferencesPromptHistory.items().isEmpty)
    }
}
