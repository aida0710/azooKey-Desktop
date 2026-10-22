import Foundation

/// Small text rules shared by node, list and announcement strings.
enum CandidateText {
    static func withReading(_ text: String, reading: String) -> String {
        reading.isEmpty ? text : String(format: Localization.text("candidate.withReading"), text, reading)
    }

    static func lines(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
