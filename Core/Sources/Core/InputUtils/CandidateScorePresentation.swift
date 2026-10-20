import Foundation

/// Explains the existing conditional score without changing its value.
public struct CandidateScorePresentation: Encodable, Equatable, Sendable {
    public let label: String
    public let detailDescription: String

    public init(relativeScore: Int?) {
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
