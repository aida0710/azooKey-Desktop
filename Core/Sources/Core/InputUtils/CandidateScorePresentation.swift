import Foundation

/// The palette role of a score badge. Raw values are the role names in
/// Shared/CandidatePalettes.json.
public enum CandidateScoreRole: String, Codable, Sendable {
    case scoreLow
    case scoreHigh
    case scoreUnknown

    // A visual split only; it does not change the conditional score.
    static let highThreshold = 75

    public init(relativeScore: Int?) {
        guard let relativeScore, (0...100).contains(relativeScore) else {
            self = .scoreUnknown
            return
        }
        self = relativeScore < Self.highThreshold ? .scoreLow : .scoreHigh
    }
}

/// Explains the existing conditional score without changing its value.
public struct CandidateScorePresentation: Encodable, Equatable, Sendable {
    public let label: String
    public let role: CandidateScoreRole
    public let detailDescription: String

    public init(relativeScore: Int?) {
        role = CandidateScoreRole(relativeScore: relativeScore)
        guard let relativeScore, (0...100).contains(relativeScore) else {
            label = Localization.text("candidate.score.unavailableLabel")
            detailDescription = Localization.text("candidate.score.unavailable")
            return
        }
        label = String(relativeScore)
        var lines = [String(format: Localization.text("candidate.score.value"), relativeScore)]
        if relativeScore == 100 {
            lines.append(Localization.text("candidate.score.conditional100"))
        } else if relativeScore == 0 {
            lines.append(Localization.text("candidate.score.roundedZero"))
        }
        lines.append(Self.explanation)
        detailDescription = lines.joined(separator: "\n")
    }

    public static var explanation: String {
        Localization.text("candidate.score.explanation")
    }
}
