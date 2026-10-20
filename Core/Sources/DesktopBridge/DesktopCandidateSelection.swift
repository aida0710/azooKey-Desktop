/// Pointer, accessibility and delayed IPC actions must identify the list they displayed.
struct DesktopCandidateSelection: Codable, Sendable {
    let batch: DesktopCandidateBatchReference
    let candidateID: String
}

extension DesktopCandidateSelection {
    private enum CodingKeys: String, CodingKey { case batch, candidateID }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: ["batch", "candidateID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(batch: try values.decode(DesktopCandidateBatchReference.self, forKey: .batch),
                  candidateID: try values.decode(String.self, forKey: .candidateID))
    }
}
