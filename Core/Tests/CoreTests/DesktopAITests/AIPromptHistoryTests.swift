import Core
import Foundation
import Testing

/// The history keeps instructions only. Ported from the Ubuntu prompt tests.
struct AIPromptHistoryTests {
    static func withHistory(_ test: (AIPromptHistory) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(AIPromptHistory(fileURL: directory.appendingPathComponent("azookey-tree/prompts.json")))
    }

    @Test func aMissingFileOffersThePinnedDefaults() throws {
        try Self.withHistory { history in
            let items = history.load()
            #expect(items.map(\.prompt) == AIPromptHistory.defaultPrompts)
            #expect(items.allSatisfy { $0.pinned && $0.shortcut == nil })
        }
    }

    @Test func pinsSurviveTheRecentLimitAndShortcutsAreUnique() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            try history.save("敬語", pinned: true, shortcut: shortcut)
            for index in 0..<15 {
                try history.save("指示\(index)", pinned: false, shortcut: nil, now: Date(timeIntervalSince1970: Double(index + 1)))
            }
            let items = history.load()
            #expect(items.filter { !$0.pinned }.count == AIPromptHistory.recentLimit)
            #expect(items.filter { !$0.pinned }.first?.prompt == "指示14", "most recent first")
            #expect(items.first?.prompt == "敬語", "pinned first, then the defaults saved with the first instruction")
            #expect(items.contains { $0.prompt == "敬語" && $0.shortcut == shortcut })
            #expect(throws: AIPromptHistory.Failure.duplicateShortcut) {
                try history.save("重複", pinned: true, shortcut: shortcut)
            }
            #expect(history.pinnedShortcuts().map(\.prompt) == ["敬語"])
        }
    }

    @Test func theFileIsPrivateToTheUser() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: nil)
            let file = try FileManager.default.attributesOfItem(atPath: history.fileURL.path)
            let directory = try FileManager.default.attributesOfItem(atPath: history.fileURL.deletingLastPathComponent().path)
            #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            // Saving again replaces the existing file.
            try history.save("英訳", pinned: false, shortcut: nil)
            #expect(history.load().contains { $0.prompt == "英訳" })
        }
    }

    @Test func anUnpinnedInstructionKeepsNoShortcutAndResavingMovesItToTheFront() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: KeyboardShortcut(key: "k", modifiers: [.control]),
                             now: Date(timeIntervalSince1970: 10))
            try history.save("英訳", pinned: false, shortcut: nil, now: Date(timeIntervalSince1970: 20))
            try history.save("敬語", pinned: false, shortcut: nil, now: Date(timeIntervalSince1970: 30))
            let unpinned = history.load().filter { !$0.pinned }
            #expect(unpinned.map(\.prompt) == ["敬語", "英訳"])
            #expect(unpinned.allSatisfy { $0.shortcut == nil })
        }
    }

    @Test func anUnreadableFileIsAnEmptyHistory() throws {
        try Self.withHistory { history in
            try FileManager.default.createDirectory(at: history.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"broken\":".utf8).write(to: history.fileURL)
            #expect(history.load().isEmpty)
        }
    }

    @Test func theUbuntuFileFormatIsReadAsIs() throws {
        try Self.withHistory { history in
            try FileManager.default.createDirectory(at: history.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = #"[{"prompt": "古い", "pinned": false, "lastUsed": 1}, {"prompt": "敬語", "pinned": true, "lastUsed": 2, "shortcut": {"key": "e", "modifiers": 6}}]"#
            try Data(saved.utf8).write(to: history.fileURL)
            let items = history.load()
            #expect(items.map(\.prompt) == ["敬語", "古い"])
            #expect(items.first?.shortcut == KeyboardShortcut(key: "e", modifiers: [.control, .option]))
        }
    }
}

struct DesktopShortcutTextTests {
    @Test func theTypedNotationRoundTripsWithModifiersInDisplayOrder() throws {
        let shortcut = try #require(try DesktopShortcutText.parse("Alt+Ctrl+E"))
        #expect(shortcut == KeyboardShortcut(key: "e", modifiers: [.control, .option]))
        #expect(DesktopShortcutText.text(for: shortcut) == "Ctrl+Alt+e")
        #expect(DesktopShortcutText.text(for: KeyboardShortcut(key: "s", modifiers: [.shift, .command])) == "Shift+Super+s")
        #expect(DesktopShortcutText.text(for: nil).isEmpty)
    }

    @Test func blankTextMeansNoShortcut() throws {
        #expect(try DesktopShortcutText.parse("  ") == nil)
    }

    @Test(arguments: ["e", "ee", "Ctrl+", "Ctrl+ee", "Hyper+e", "Ctrl + e", "+"])
    func otherNotationsAreRejected(text: String) {
        let expected: DesktopShortcutText.Failure = text == "e" ? .modifierRequired : .format
        #expect(throws: expected) { try DesktopShortcutText.parse(text) }
    }
}
