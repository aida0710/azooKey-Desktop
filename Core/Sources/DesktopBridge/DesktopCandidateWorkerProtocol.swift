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
    var settings: DesktopWorkerSettings?

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
    var settingsContract: String?
    var settings: DesktopWorkerSettings?
    var unsupportedFeatures: [String]?
    var error: String?
}

extension DesktopCandidateWorkerRequest {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation, request, reference, completion, workerGeneration, settingsRevision, learning
        case context, readingProcessGeneration, settings
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try fields.decode(String.self, forKey: .operation)
        if operation == "configure-settings" {
            try DesktopReadingProtocolValidation.keys(decoder, allowed: ["operation", "workerGeneration", "settingsRevision", "settings"])
        }
        self.init(operation: operation,
                  request: try fields.decodeIfPresent(DesktopCandidateRequest.self, forKey: .request),
                  reference: try fields.decodeIfPresent(DesktopCandidateBatchReference.self, forKey: .reference),
                  completion: try fields.decodeIfPresent(DesktopCandidateCompletion.self, forKey: .completion),
                  workerGeneration: try fields.decodeIfPresent(String.self, forKey: .workerGeneration),
                  settingsRevision: try fields.decodeIfPresent(Int.self, forKey: .settingsRevision),
                  learning: try fields.decodeIfPresent(Config.Learning.Value.self, forKey: .learning),
                  context: try fields.decodeIfPresent(String.self, forKey: .context),
                  readingProcessGeneration: try fields.decodeIfPresent(String.self, forKey: .readingProcessGeneration),
                  settings: try fields.decodeIfPresent(DesktopWorkerSettings.self, forKey: .settings))
    }
}
