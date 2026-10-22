import Core

/// Pure candidate presentation operations. They need no input session, so
/// renderers can call them with their own measurements at any time.
enum DesktopCandidateController {
    static func response(to request: BridgeRequest) throws -> DesktopSnapshot? {
        switch request.operation {
        case "candidate-layout":
            guard let layout = request.layout else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            var response = DesktopSnapshot()
            response.candidateLayout = CandidateLayout(layout)
            return response
        case "candidate-display":
            guard let snapshot = request.snapshot else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            var response = DesktopSnapshot()
            response.candidateDisplay = CandidateDisplay(snapshot)
            return response
        default:
            return nil
        }
    }
}
