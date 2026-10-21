import Core

/// A dictionary-only query, bound to the reading owner that may later prepare deletion.
struct DesktopReconversionReadingRequest: Codable {
    let authority: CandidateRequestAuthority
    let workerGeneration: String
    let text: String
    let privateInput: Bool

    func matches(_ other: Self) -> Bool {
        authority == other.authority && workerGeneration == other.workerGeneration
            && text.utf8.elementsEqual(other.text.utf8) && privateInput == other.privateInput
    }

    func validate() throws {
        try DesktopCandidateValidation.authority(authority)
        try DesktopCandidateValidation.identifier(workerGeneration)
        guard !text.isEmpty, text.unicodeScalars.count <= ReconversionContext.selectionLimit else {
            throw DesktopCandidateFailure.invalidRequest
        }
        guard !privateInput else { throw ReconversionSession.Failure.privateInput }
    }

    private enum CodingKeys: String, CodingKey { case authority, workerGeneration, text, privateInput }

    init(authority: CandidateRequestAuthority, workerGeneration: String, text: String, privateInput: Bool) {
        self.authority = authority
        self.workerGeneration = workerGeneration
        self.text = text
        self.privateInput = privateInput
    }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: ["authority", "workerGeneration", "text", "privateInput"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try DesktopReadingProtocolValidation.keys(values.superDecoder(forKey: .authority), allowed: [
            "context", "readingProcessGeneration", "focusEpoch", "compositionRevision", "settingsRevision", "requestID"
        ])
        self.init(authority: try values.decode(CandidateRequestAuthority.self, forKey: .authority),
                  workerGeneration: try values.decode(String.self, forKey: .workerGeneration),
                  text: try values.decode(String.self, forKey: .text),
                  privateInput: try values.decode(Bool.self, forKey: .privateInput))
    }
}

struct DesktopReconversionReadingResult: Codable {
    let request: DesktopReconversionReadingRequest
    let reading: String?

    private enum CodingKeys: String, CodingKey { case request, reading }

    init(request: DesktopReconversionReadingRequest, reading: String?) {
        self.request = request
        self.reading = reading
    }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: ["request", "reading"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(request: try values.decode(DesktopReconversionReadingRequest.self, forKey: .request),
                  reading: try values.decodeIfPresent(String.self, forKey: .reading))
    }
}
