import Core
import Foundation

/// Exchange reads a selected file or serializes a draft; only dictionary-save persists settings.
@MainActor
enum DesktopDictionaryExchangeController {
    private struct ImportResult: Sendable {
        let preview: UserDictionaryImportPreview.Preview
        let items: [Config.UserDictionaryEntry]
    }

    static func response(to request: BridgeRequest) async throws -> DesktopSnapshot? {
        switch request.operation {
        case "dictionary-import-preview":
            return try await preview(request)
        case "dictionary-export":
            guard let items = request.items else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            var response = DesktopSnapshot()
            do {
                response.dictionaryExportJSON = try await UserDictionaryFileWorker.perform {
                    let content = try UserDictionaryExchange.export(items)
                    guard let json = String(data: content, encoding: .utf8) else {
                        throw UserDictionaryExchange.Failure.invalidDocument
                    }
                    return json
                }
            } catch {
                response.dictionaryExchangeError = "exportFailed"
            }
            return response
        default:
            return nil
        }
    }

    private static func preview(_ request: BridgeRequest) async throws -> DesktopSnapshot {
        guard let items = request.items, let path = request.importPath,
              let format = request.importFormat, let encoding = request.importEncoding else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
        var response = DesktopSnapshot()
        do {
            let imported = try await UserDictionaryFileWorker.perform {
                let source = URL(fileURLWithPath: path)
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw UserDictionaryExchange.Failure.invalidDocument
                }
                let document = try UserDictionaryExchange.parse(Data(contentsOf: source), format: format, encoding: encoding)
                let preview = try UserDictionaryImportPreview.make(document: document, existing: items)
                return ImportResult(preview: preview, items: try UserDictionaryImportPreview.applying(preview, to: items))
            }
            response.dictionaryImportPreview = imported.preview
            response.dictionaryImportItems = imported.items
        } catch {
            response.dictionaryExchangeError = publicFailure(error)
        }
        return response
    }

    private static func publicFailure(_ error: any Error) -> String {
        if error is UserDictionaryValidation.ResourceError {
            return "missingResources"
        }
        guard let failure = error as? UserDictionaryExchange.Failure else {
            return "importFailed"
        }
        switch failure {
        case .unknownEncoding: return "unknownEncoding"
        case .invalidEncoding: return "invalidEncoding"
        case .unsupportedBinary: return "unsupportedBinary"
        case .unsupportedFormat: return "unsupportedFormat"
        case .unsupportedVersion: return "unsupportedVersion"
        case .invalidDocument: return "invalidDocument"
        case .stalePreview: return "stalePreview"
        }
    }
}
