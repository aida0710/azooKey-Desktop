import Core
import Foundation

struct AISuggestionConfirmation {
    let reading: String
    let clientIdentity: ObjectIdentifier
    let selectedRange: NSRange
    let configuration: AIRequestConfiguration
    var includeContext: Bool
}

