import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Instructions the user gave the selected-text AI, never the document text.
/// Pinned instructions stay and may carry a shortcut; the most recent
/// unpinned ones are kept up to `recentLimit`.
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

    /// Offered until the user saves an instruction of their own.
    public static let defaultPrompts = ["elaborate", "rewrite", "formal", "english"]
    public static let recentLimit = 10

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Pinned first, then most recently used. An unreadable file is an empty
    /// history rather than a reason to stop offering the prompt.
    public func load() -> [Item] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Self.defaultPrompts.map { Item(prompt: $0, pinned: true, lastUsed: 0, shortcut: nil) }
        }
        guard let data = try? Data(contentsOf: fileURL), let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        // Enumerated so equal keys keep their saved order.
        return items.enumerated().sorted { first, second in
            if first.element.pinned != second.element.pinned {
                return first.element.pinned
            }
            if first.element.lastUsed != second.element.lastUsed {
                return first.element.lastUsed > second.element.lastUsed
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// Moves `prompt` to the front. A shortcut is kept only for a pinned
    /// instruction, but it must not duplicate another instruction's shortcut.
    public func save(_ prompt: String, pinned: Bool, shortcut: KeyboardShortcut?) throws(Failure) {
        try save(prompt, pinned: pinned, shortcut: shortcut, usedAt: Date())
    }

    /// `usedAt` orders the unpinned history. This is an overload, not a
    /// `Date()` default argument: on Linux, type-checking that default while
    /// the module interface is emitted loads Foundation's C headers before
    /// Glibc's, and `stat` in Desktop/Settings can then no longer be found.
    public func save(_ prompt: String, pinned: Bool, shortcut: KeyboardShortcut?, usedAt: Date) throws(Failure) {
        var items = load().filter { !$0.prompt.hasSameScalars(as: prompt) }
        if let shortcut, items.contains(where: { $0.shortcut == shortcut }) {
            throw .duplicateShortcut
        }
        items.insert(Item(prompt: prompt, pinned: pinned, lastUsed: usedAt.timeIntervalSince1970, shortcut: pinned ? shortcut : nil), at: 0)
        let kept = items.filter(\.pinned) + items.filter { !$0.pinned }.prefix(Self.recentLimit)
        do {
            try write(kept)
        } catch {
            throw .saveFailed
        }
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

    private func write(_ items: [Item]) throws {
        let directory = fileURL.deletingLastPathComponent()
        // The instructions are private to the user, like the settings beside them.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(items)
        #if os(Windows)
        // Windows has no POSIX modes; Foundation replaces the file in one step.
        try data.write(to: fileURL, options: .atomic)
        #else
        // Created private from the start (an atomic Data write starts at 0644),
        // then renamed over the old file so a reader never sees a partial file.
        // Foundation's replaceItemAt does not work on Linux.
        let temporaryURL = directory.appendingPathComponent(".prompts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporaryURL.path, fileURL.path) == 0 else {
            throw Failure.saveFailed
        }
        #endif
    }
}
