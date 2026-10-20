import Core
import Foundation

/// File access and parsing run outside the main actor; applying a preview stays in the editor model.
enum UserDictionaryFileExchangeService {
    struct ImportOptions: Sendable {
        let format: UserDictionaryExchange.Format
        let encoding: UserDictionaryExchange.TextEncoding
    }

    static func preview(
        from url: URL, options: ImportOptions, existing: [Config.UserDictionaryEntry],
        charIDFileURL: URL? = nil
    ) async throws -> UserDictionaryImportPreview.Preview {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let content = try Data(contentsOf: url)
            let document = try UserDictionaryExchange.parse(content, format: options.format, encoding: options.encoding)
            return try UserDictionaryImportPreview.make(document: document, existing: existing, charIDFileURL: charIDFileURL)
        }.value
    }

    static func export(_ entries: [Config.UserDictionaryEntry], to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let content = try UserDictionaryExchange.export(entries)
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            try content.write(to: url, options: .atomic)
        }.value
    }
}
