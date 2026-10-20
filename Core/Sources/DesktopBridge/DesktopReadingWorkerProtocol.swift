import Core

struct DesktopReadingContextReference: Codable, Equatable {
    let context: String
    let readingProcessGeneration: String
    let focusEpoch: Int
}

extension DesktopReadingContextReference {
    private enum CodingKeys: String, CodingKey { case context, readingProcessGeneration, focusEpoch }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: ["context", "readingProcessGeneration", "focusEpoch"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(context: try values.decode(String.self, forKey: .context),
                  readingProcessGeneration: try values.decode(String.self, forKey: .readingProcessGeneration),
                  focusEpoch: try values.decode(Int.self, forKey: .focusEpoch))
    }
}

/// Private, explicit reading-role protocol. It cannot decode ordinary BridgeRequest messages.
struct DesktopReadingWorkerRequest: Codable {
    let operation: String
    var readingProcessGeneration: String?
    var context: String?
    var reference: DesktopReadingContextReference?
    var surroundings: DesktopReadingSurroundings?
    var event: KeyEventCore?
    var submit: Bool?
    var doubleTap: Bool?
    var candidateWorkerGeneration: String?
    var batch: DesktopCandidateBatch?
    var retainedReference: DesktopCandidateBatchReference?
    var selection: DesktopCandidateSelection?
    var settingsRevision: Int?
    var settings: DesktopWorkerSettings?

    private static let payloadFields: [String: Set<String>] = [
        "hello": [],
        "settings": [],
        "configure-settings": ["readingProcessGeneration", "settingsRevision", "settings"],
        "open": ["readingProcessGeneration", "context"],
        "focus-in": ["reference", "surroundings"],
        "focus-out": ["reference", "submit"],
        "reset": ["reference", "submit"],
        "key": ["reference", "event", "doubleTap"],
        "snapshot": ["reference"],
        "close": ["reference"],
        "prepare-candidates": ["reference", "candidateWorkerGeneration"],
        "candidate-worker-stopped": ["reference", "candidateWorkerGeneration"],
        "adopt-candidates": ["reference", "batch", "retainedReference"],
        "select": ["reference", "selection"],
        "commit-candidate": ["reference", "selection"],
        "learning-revision": ["readingProcessGeneration", "settingsRevision"]
    ]

    static func allowedFields(for operation: String) throws -> Set<String> {
        guard let payload = payloadFields[operation] else { throw DesktopReadingProtocolFailure.unsupportedOperation }
        return payload.union(["operation"])
    }
}

extension DesktopReadingWorkerRequest {
    private enum CodingKeys: String, CodingKey {
        case operation, readingProcessGeneration, context, reference, surroundings, event, submit, doubleTap
        case candidateWorkerGeneration, batch, retainedReference, selection, settingsRevision, settings
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try values.decode(String.self, forKey: .operation)
        try DesktopReadingProtocolValidation.keys(decoder, allowed: Self.allowedFields(for: operation))
        let event: KeyEventCore?
        if values.contains(.event), try !values.decodeNil(forKey: .event) {
            let eventDecoder = try values.superDecoder(forKey: .event)
            try DesktopReadingProtocolValidation.keys(eventDecoder, allowed: [
                "keyCode", "characters", "charactersIgnoringModifiers", "modifierFlags"
            ])
            event = try KeyEventCore(from: eventDecoder)
        } else {
            event = nil
        }
        self.init(operation: operation,
                  readingProcessGeneration: try values.decodeIfPresent(String.self, forKey: .readingProcessGeneration),
                  context: try values.decodeIfPresent(String.self, forKey: .context),
                  reference: try values.decodeIfPresent(DesktopReadingContextReference.self, forKey: .reference),
                  surroundings: try values.decodeIfPresent(DesktopReadingSurroundings.self, forKey: .surroundings),
                  event: event,
                  submit: try values.decodeIfPresent(Bool.self, forKey: .submit),
                  doubleTap: try values.decodeIfPresent(Bool.self, forKey: .doubleTap),
                  candidateWorkerGeneration: try values.decodeIfPresent(String.self, forKey: .candidateWorkerGeneration),
                  batch: try values.decodeIfPresent(DesktopCandidateBatch.self, forKey: .batch),
                  retainedReference: try values.decodeIfPresent(DesktopCandidateBatchReference.self, forKey: .retainedReference),
                  selection: try values.decodeIfPresent(DesktopCandidateSelection.self, forKey: .selection),
                  settingsRevision: try values.decodeIfPresent(Int.self, forKey: .settingsRevision),
                  settings: try values.decodeIfPresent(DesktopWorkerSettings.self, forKey: .settings))
    }
}

/// Only an input response contains a snapshot; candidate/control replies cannot replay preedit.
struct DesktopReadingWorkerResponse: Encodable {
    enum Kind: String, Encodable { case process, acknowledgement, candidates, input, error }
    let kind: Kind
    let readingProcessGeneration: String
    let settingsRevision: Int
    var reference: DesktopReadingContextReference?
    var nextReference: DesktopReadingContextReference?
    var snapshot: DesktopSnapshot?
    var candidateRequest: DesktopCandidateRequest?
    var candidateReference: DesktopCandidateBatchReference?
    var candidateView: DesktopCandidateView?
    var limits: [String: Int]?
    var settingsContract: String?
    var settings: DesktopWorkerSettings?
    var customInputTableRevisions: [String: String]?
    var unsupportedFeatures: [String]?
    var defaultSettings: DesktopWorkerSettings?
    var defaultSettingsError: String?
    var error: String?
}
