import Core

/// Private JSONL protocol for the explicit candidate role; ordinary bridge requests are unchanged.
struct DesktopCandidateWorkerRequest: Decodable {
    let operation: String
    var request: DesktopCandidateRequest?
    var reference: DesktopCandidateBatchReference?
    var completion: DesktopCandidateCompletion?
    var workerGeneration: String?
    var settingsRevision: Int?
    var learning: Config.Learning.Value?
    var context: String?
    var readingProcessGeneration: String?

    var authority: CandidateRequestAuthority? {
        switch operation {
        case "candidates": request?.authority
        case "retain", "release": reference?.authority
        case "complete": completion?.authority
        default: nil
        }
    }
}

struct DesktopCandidateWorkerResponse: Encodable {
    let workerGeneration: String
    let settingsRevision: Int
    var authority: CandidateRequestAuthority?
    var batch: DesktopCandidateBatch?
    var completion: DesktopCandidateCompletionResult?
    var reference: DesktopCandidateBatchReference?
    var learning: Config.Learning.Value?
    var customInputTableRevisions: [String: String]?
    var error: String?
}
