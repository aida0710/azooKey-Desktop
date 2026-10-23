import Foundation

/// Instructions the user gave the selected-text AI, never the document text.
/// Pinned instructions stay and may carry a shortcut; the most recent
/// unpinned ones are kept up to `recentLimit`. Until the user uses them, the
/// default instructions are shown in the language the settings choose.
public struct AIPromptHistory: Sendable {
    public struct Item: Codable, Sendable {
        public var prompt: String
        public var pinned: Bool
        /// Seconds since 1970; orders the unpinned history.
        public var lastUsed: Double
        public var shortcut: KeyboardShortcut?

        public init(prompt: String, pinned: Bool, lastUsed: Double, shortcut: KeyboardShortcut?) {
            self.prompt = prompt
            self.pinned = pinned
            self.lastUsed = lastUsed
            self.shortcut = shortcut
        }
    }

    public enum Failure: String, Error, Codable, Sendable {
        /// Another pinned instruction already uses the shortcut.
        case duplicateShortcut
        /// The history file could not be written.
        case saveFailed
    }

    /// The default instructions' names in `ai.example.*`, in the order they
    /// are offered. Earlier versions offered these English words themselves.
    private static let defaultPromptNames = ["elaborate", "rewrite", "formal", "english"]
    public static let recentLimit = 10

    public let fileURL: URL
    /// Nil follows the settings, read at each use, so a running bridge shows
    /// a changed language without opening the history again.
    private let fixedLanguage: Localization.Language?

    /// The default instructions follow `Config.AIPromptLanguage`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.fixedLanguage = nil
    }

    /// The default instructions are shown in `language`, whatever the settings say.
    public init(fileURL: URL, language: Localization.Language) {
        self.fileURL = fileURL
        self.fixedLanguage = language
    }

    /// The default instructions in `language`, offered pinned to a new user.
    public static func defaultPrompts(in language: Localization.Language) -> [String] {
        defaultPromptNames.map { defaultPrompt(named: $0, in: language) }
    }

    /// Pinned first, then most recently used. An unreadable file is an empty
    /// history rather than a reason to stop offering the prompt. Default
    /// instructions not used yet are shown in the current language.
    public func load() -> [Item] {
        let defaults = Self.defaultPrompts(in: fixedLanguage ?? Config.AIPromptLanguage().value)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaults.map(Self.unusedDefault)
        }
        guard let data = try? Data(contentsOf: fileURL), let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        return Self.ranked(Self.showingUnusedDefaults(items, as: defaults))
    }

    /// Moves `prompt` to the front. A shortcut is kept only for a pinned
    /// instruction, but it must not duplicate another instruction's shortcut.
    public func save(_ prompt: String, pinned: Bool, shortcut: KeyboardShortcut?) throws(Failure) {
        try save(prompt, pinned: pinned, shortcut: shortcut, usedAt: Date())
    }

    /// `usedAt` orders the unpinned history.
    public func save(_ prompt: String, pinned: Bool, shortcut: KeyboardShortcut?, usedAt: Date) throws(Failure) {
        var items = load().filter { !$0.prompt.hasSameScalars(as: prompt) }
        if let shortcut, items.contains(where: { $0.shortcut == shortcut }) {
            throw .duplicateShortcut
        }
        items.insert(Item(prompt: prompt, pinned: pinned, lastUsed: usedAt.timeIntervalSince1970, shortcut: pinned ? shortcut : nil), at: 0)
        try store(items)
    }

    /// Records that `prompt` was used again: it moves to the front and keeps
    /// the pin and shortcut it already has. A new instruction starts unpinned.
    public func recordUse(_ prompt: String) throws(Failure) {
        let existing = load().first { $0.prompt.hasSameScalars(as: prompt) }
        try save(prompt, pinned: existing?.pinned ?? false, shortcut: existing?.shortcut, usedAt: Date())
    }

    /// Starts the history from one kept elsewhere, such as the preferences of
    /// an earlier macOS version. Does nothing once the history file exists.
    /// The items are ranked like `load()`; the first of equal instructions is
    /// kept, a shortcut stays only on a pinned item where it first appears,
    /// and at most `recentLimit` unpinned items remain.
    public func importItems(_ items: [Item]) throws(Failure) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        var imported: [Item] = []
        var usedShortcuts: Set<KeyboardShortcut> = []
        for var item in Self.ranked(items) where !imported.contains(where: { $0.prompt.hasSameScalars(as: item.prompt) }) {
            if !item.pinned || item.shortcut.map(usedShortcuts.contains) == true {
                item.shortcut = nil
            }
            if let shortcut = item.shortcut {
                usedShortcuts.insert(shortcut)
            }
            imported.append(item)
        }
        try store(imported)
    }

    /// Shortcuts of pinned instructions, in history order.
    public func pinnedShortcuts() -> [(shortcut: KeyboardShortcut, prompt: String)] {
        load().compactMap { item in
            guard item.pinned, let shortcut = item.shortcut else {
                return nil
            }
            return (shortcut, item.prompt)
        }
    }

    private static func defaultPrompt(named name: String, in language: Localization.Language) -> String {
        Localization.text("ai.example.\(name)", language: language)
    }

    /// How a default instruction is offered before the user uses it.
    private static func unusedDefault(_ prompt: String) -> Item {
        Item(prompt: prompt, pinned: true, lastUsed: 0, shortcut: nil)
    }

    /// Every text a default instruction may have been saved with, by position:
    /// the English word of earlier versions and its text in each language.
    private static let defaultPromptTexts: [[String]] = defaultPromptNames.map { name in
        [name] + Localization.Language.allCases.map { defaultPrompt(named: name, in: $0) }
    }

    /// The position of a default instruction the user has not yet used,
    /// unpinned or given a shortcut to; nil for every other instruction.
    private static func unusedDefaultPosition(of item: Item) -> Int? {
        guard item.pinned, item.lastUsed == 0, item.shortcut == nil else {
            return nil
        }
        return defaultPromptTexts.firstIndex { texts in texts.contains { $0.hasSameScalars(as: item.prompt) } }
    }

    /// Replaces each unused default with the default at its position in
    /// `defaults`. A default whose text is already shown is left out, so an
    /// instruction the user saved with that text is not listed twice.
    private static func showingUnusedDefaults(_ items: [Item], as defaults: [String]) -> [Item] {
        let positions = items.map(unusedDefaultPosition)
        var shownPrompts = zip(items, positions).compactMap { item, position in position == nil ? item.prompt : nil }
        return zip(items, positions).compactMap { item, position in
            guard let position else {
                return item
            }
            let prompt = defaults[position]
            guard !shownPrompts.contains(where: { $0.hasSameScalars(as: prompt) }) else {
                return nil
            }
            shownPrompts.append(prompt)
            return unusedDefault(prompt)
        }
    }

    /// Pinned first, then most recently used. Enumerated so equal keys keep
    /// their saved order.
    private static func ranked(_ items: [Item]) -> [Item] {
        items.enumerated().sorted { first, second in
            if first.element.pinned != second.element.pinned {
                return first.element.pinned
            }
            if first.element.lastUsed != second.element.lastUsed {
                return first.element.lastUsed > second.element.lastUsed
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// Keeps every pinned instruction and the first `recentLimit` unpinned ones.
    private func store(_ items: [Item]) throws(Failure) {
        let kept = items.filter(\.pinned) + items.filter { !$0.pinned }.prefix(Self.recentLimit)
        do {
            try write(kept)
        } catch {
            throw .saveFailed
        }
    }

    private func write(_ items: [Item]) throws {
        let directory = fileURL.deletingLastPathComponent()
        // The instructions are private to the user, like the settings beside them.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: PlatformFileOperations.ownerOnlyAttributes(0o700))
        let data = try JSONEncoder().encode(items)
        // Created private from the start (an atomic Data write starts at 0644),
        // then moved over the old file so a reader never sees a partial file.
        // Foundation's replaceItemAt does not work on Linux.
        let temporaryURL = directory.appendingPathComponent(".prompts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data,
                                             attributes: PlatformFileOperations.ownerOnlyAttributes(0o600)) else {
            throw Failure.saveFailed
        }
        do {
            try PlatformFileOperations.replaceFile(temporaryURL, to: fileURL)
        } catch {
            throw Failure.saveFailed
        }
    }
}
