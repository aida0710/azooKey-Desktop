import AppKit

@MainActor
enum CandidateNumberFont {
    static func make(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        // SF Mono can raise a CoreText exception on first badge drawing in a
        // fresh login session. Candidate numbers only need equal-width digits.
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
