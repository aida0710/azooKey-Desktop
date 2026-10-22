import Core
import Foundation

/// Operations that need no input session: the support report and the
/// personalization model import. Requests carry their own fields, so these
/// operations do not extend `BridgeRequest`.
@MainActor
enum DesktopServiceController {
    /// Each platform's settings screen sends the environment values it can read.
    private struct SupportDiagnosticsRequest: Decodable {
        #if os(Windows)
        var supportEnvironment: SupportDiagnostics.WindowsEnvironment
        #else
        var supportEnvironment: SupportDiagnostics.LinuxEnvironment
        #endif
        var language: Localization.Language

        var diagnostics: SupportDiagnostics {
            #if os(Windows)
            SupportDiagnostics.windows(supportEnvironment)
            #else
            SupportDiagnostics.linux(supportEnvironment)
            #endif
        }
    }

    private struct PersonalizationImportRequest: Decodable {
        var importPath: String
    }

    struct Response: Encodable {
        var supportDiagnostics: String?
        var personalizationImported: Bool?
        var personalizationFailure: PersonalizationModelImport.Failure?
    }

    static func response(to operation: String, line: String, dataDirectory: URL) throws -> Response? {
        switch operation {
        case "support-diagnostics":
            let request = try decode(SupportDiagnosticsRequest.self, from: line)
            return Response(supportDiagnostics: request.diagnostics.report(language: request.language))
        case "import-personalization":
            let request = try decode(PersonalizationImportRequest.self, from: line)
            let root = dataDirectory.appendingPathComponent(PersonalizationModelImport.directoryName, isDirectory: true)
            do {
                try PersonalizationModelImport.importModel(from: URL(fileURLWithPath: request.importPath, isDirectory: true), into: root)
                return Response(personalizationImported: true)
            } catch let failure as PersonalizationModelImport.Failure {
                return Response(personalizationImported: false, personalizationFailure: failure)
            }
        default:
            return nil
        }
    }

    private static func decode<Request: Decodable>(_ type: Request.Type, from line: String) throws -> Request {
        do {
            return try JSONDecoder().decode(type, from: Data(line.utf8))
        } catch {
            throw BridgeMain.ProtocolError.invalidRequest
        }
    }
}
