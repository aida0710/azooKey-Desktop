import Core

enum TransformationPreviewError: Error {
    case targetChanged
    case missingAPIKey
    case requestFailed

    var message: String {
        let key: String
        switch self {
        case .targetChanged: key = "ai.error.target-changed"
        case .missingAPIKey: key = "ai.error.missing-key"
        case .requestFailed: key = "ai.suggestion.failed"
        }
        return Localization.text(key)
    }
}
