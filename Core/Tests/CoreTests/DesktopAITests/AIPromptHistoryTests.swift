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
                try history.save("指示\(index)", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: Double(index + 1)))
            }
            let items = history.load()
            #expect(items.filter { !$0.pinned }.count == AIPromptHistory.recentLimit)
            #expect(items.first { !$0.pinned }?.prompt == "指示14", "most recent first")
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
                             usedAt: Date(timeIntervalSince1970: 10))
            try history.save("英訳", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: 20))
            try history.save("敬語", pinned: false, shortcut: nil, usedAt: Date(timeIntervalSince1970: 30))
            let unpinned = history.load().filter { !$0.pinned }
            #expect(unpinned.map(\.prompt) == ["敬語", "英訳"])
            #expect(unpinned.allSatisfy { $0.shortcut == nil })
        }
    }

    @Test func recordingAUseKeepsThePinAndShortcutAndANewInstructionStartsUnpinned() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            try history.save("敬語", pinned: true, shortcut: shortcut, usedAt: Date(timeIntervalSince1970: 10))
            try history.recordUse("英訳")
            try history.recordUse("敬語")
            let items = history.load()
            #expect(items.first { $0.prompt == "敬語" }?.pinned == true)
            #expect(items.first { $0.prompt == "敬語" }?.shortcut == shortcut)
            #expect(items.first { $0.prompt == "英訳" }?.pinned == false)
            #expect(items.first { $0.pinned }?.prompt == "敬語", "the used pinned instruction moves to the front")
        }
    }

    @Test func importedItemsAreRankedAndKeepOnlyTheFirstShortcutOfAPinnedInstruction() throws {
        try Self.withHistory { history in
            let shortcut = KeyboardShortcut(key: "e", modifiers: [.control, .option])
            let other = KeyboardShortcut(key: "k", modifiers: [.control])
            var items = [
                AIPromptHistory.Item(prompt: "古い固定", pinned: true, lastUsed: 1, shortcut: shortcut),
                AIPromptHistory.Item(prompt: "新しい固定", pinned: true, lastUsed: 2, shortcut: shortcut),
                AIPromptHistory.Item(prompt: "固定しない", pinned: false, lastUsed: 3, shortcut: other),
                AIPromptHistory.Item(prompt: "固定しない", pinned: false, lastUsed: 0, shortcut: nil)
            ]
            items += (0..<15).map { AIPromptHistory.Item(prompt: "指示\($0)", pinned: false, lastUsed: 0, shortcut: nil) }
            try history.importItems(items)
            let imported = history.load()
            #expect(imported.prefix(3).map(\.prompt) == ["新しい固定", "古い固定", "固定しない"])
            #expect(imported.map(\.shortcut).prefix(3) == [shortcut, nil, nil])
            #expect(imported.filter { $0.prompt == "固定しない" }.count == 1)
            #expect(imported.filter { !$0.pinned }.count == AIPromptHistory.recentLimit)
            #expect(imported.last?.prompt == "指示8", "equal times keep the imported order")
        }
    }

    @Test func importingDoesNothingOnceTheHistoryFileExists() throws {
        try Self.withHistory { history in
            try history.save("敬語", pinned: false, shortcut: nil)
            try history.importItems([AIPromptHistory.Item(prompt: "古い", pinned: true, lastUsed: 1, shortcut: nil)])
            #expect(!history.load().contains { $0.prompt == "古い" })
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
