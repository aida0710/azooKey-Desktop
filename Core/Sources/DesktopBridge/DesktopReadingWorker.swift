import Foundation

/// Owns reading contexts in a process that never creates a converter or learning store.
@MainActor
struct DesktopReadingWorker {
    private var sessions: [String: DesktopReadingSession] = [:]

    mutating func process(_ request: BridgeRequest) throws -> DesktopSnapshot {
        let context = request.context ?? "default"
        if request.operation == "close" {
            sessions.removeValue(forKey: context)
            return DesktopSnapshot()
        }
        var session = sessions[context] ?? DesktopReadingSession()
        let response: DesktopSnapshot
        switch request.operation {
        case "key":
            guard let event = request.event else { throw BridgeMain.ProtocolError.invalidRequest }
            response = try session.key(event, doubleTap: request.doubleTap ?? false)
        case "reset":
            response = session.reset(commit: request.submit ?? false)
        case "snapshot":
            response = session.snapshot()
        default:
            throw BridgeMain.ProtocolError.invalidRequest
        }
        sessions[context] = session
        return response
    }

    func rejected(_ request: BridgeRequest, error: Error) -> DesktopSnapshot {
        var response = sessions[request.context ?? "default"]?.snapshot() ?? DesktopSnapshot()
        response.consumed = false
        response.error = (error as? DesktopReadingSession.Failure)?.rawValue ?? "invalid_request"
        return response
    }

    static func run(output: FileHandle) throws {
        var worker = Self()
        while let line = readLine() {
            let response: DesktopSnapshot
            do {
                let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8))
                do {
                    response = try worker.process(request)
                } catch {
                    response = worker.rejected(request, error: error)
                }
            } catch {
                var invalid = DesktopSnapshot()
                invalid.consumed = false
                invalid.error = "invalid_request"
                response = invalid
            }
            try BridgeMain.write(response, to: output)
        }
    }
}
