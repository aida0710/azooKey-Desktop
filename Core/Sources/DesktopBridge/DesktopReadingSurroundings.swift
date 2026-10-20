/// Native context bound to one focus lifetime; it is never inferred from the reading.
struct DesktopReadingSurroundings: Codable {
    let leftContext: String
    let rightContext: String
    let privateInput: Bool

    func bounded() -> Self {
        .init(leftContext: String(leftContext.suffix(DesktopWorkerProtocolLimits.surroundingCharacters)),
              rightContext: String(rightContext.prefix(DesktopWorkerProtocolLimits.surroundingCharacters)),
              privateInput: privateInput)
    }

    func appending(_ commits: [String]) -> Self {
        .init(leftContext: Self.appending(commits, to: leftContext), rightContext: rightContext,
              privateInput: privateInput)
    }

    static func appending(_ commits: [String], to leftContext: String) -> String {
        String((leftContext + commits.joined()).suffix(DesktopWorkerProtocolLimits.surroundingCharacters))
    }
}

extension DesktopReadingSurroundings {
    private enum CodingKeys: String, CodingKey { case leftContext, rightContext, privateInput }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: ["leftContext", "rightContext", "privateInput"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(leftContext: try values.decode(String.self, forKey: .leftContext),
                  rightContext: try values.decode(String.self, forKey: .rightContext),
                  privateInput: try values.decode(Bool.self, forKey: .privateInput))
    }
}
