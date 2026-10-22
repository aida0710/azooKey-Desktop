import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum UserDictionaryFilePanels {
    static func previewImport(
        existing: [Config.UserDictionaryEntry], window: NSWindow?
    ) async throws -> UserDictionaryImportPreview.Preview? {
        let panel = NSOpenPanel()
        let options = UserDictionaryImportOptions()
        panel.title = UserDictionaryMessages.text("importTitle")
        panel.prompt = UserDictionaryMessages.text("importPreview")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Export tools use different extensions. The chosen format and decoder validate the contents.
        panel.allowsOtherFileTypes = true
        let accessory = NSHostingView(rootView: UserDictionaryImportOptionsView(options: options))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard await present(panel, for: window) == .OK, let url = panel.url else {
            return nil
        }
        return try await UserDictionaryFileExchangeService.preview(from: url, options: options.selected, existing: existing)
    }

    static func export(_ entries: [Config.UserDictionaryEntry], window: NSWindow?) async throws -> Bool {
        let panel = NSSavePanel()
        panel.title = UserDictionaryMessages.text("exportTitle")
        panel.prompt = UserDictionaryMessages.text("export")
        panel.message = UserDictionaryMessages.text("exportHelp")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "azookey-user-dictionary.json"
        guard await present(panel, for: window) == .OK, let url = panel.url else {
            return false
        }
        try await UserDictionaryFileExchangeService.export(entries, to: url)
        return true
    }

    private static func present(_ panel: NSSavePanel, for window: NSWindow?) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { continuation.resume(returning: $0) }
            if let window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}
