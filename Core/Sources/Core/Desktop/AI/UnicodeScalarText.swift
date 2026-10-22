import Foundation

/// Document text is compared scalar by scalar. Swift's `String ==` treats
/// canonically equivalent text (か + U+3099 and が) as equal, but a replacement
/// must only reach the exact text that was reviewed.
extension String {
    func hasSameScalars(as other: String) -> Bool {
        unicodeScalars.elementsEqual(other.unicodeScalars)
    }

    func hasScalarPrefix(_ prefix: String) -> Bool {
        unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    func hasScalarSuffix(_ suffix: String) -> Bool {
        unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }

    func scalarPrefix(_ count: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.prefix(count)))
    }

    func scalarSuffix(_ count: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.suffix(count)))
    }
}
