import Core
import Foundation

enum UserDictionaryExchangeFeedback {
    static func failureKey(_ error: any Error, operation: UserDictionaryFileOperation) -> String {
        if error is UserDictionaryValidation.ResourceError {
            return "missingResources"
        }
        guard let failure = error as? UserDictionaryExchange.Failure else {
            return operation == .importing ? "importFailed" : "exportFailed"
        }
        switch failure {
        case .unknownEncoding: return "importUnknownEncoding"
        case .invalidEncoding: return "importInvalidEncoding"
        case .unsupportedBinary: return "importBinaryUnsupported"
        case .unsupportedFormat: return "importFormatUnsupported"
        case .unsupportedVersion: return "importVersionUnsupported"
        case .invalidDocument: return "importInvalidDocument"
        case .stalePreview: return "importStalePreview"
        }
    }

    static func validationReason(_ issue: UserDictionaryValidation.Issue) -> String {
        let key: String
        switch (issue.field, issue.reason) {
        case (.word, .empty): key = "emptyWord"
        case (.reading, .empty): key = "emptyReading"
        case (.word, .controlCharacter): key = "controlWord"
        case (.reading, .controlCharacter): key = "controlReading"
        default: key = "unsupportedReading"
        }
        return UserDictionaryMessages.text(key)
    }

    static func importReason(_ row: UserDictionaryImportPreview.Row) -> String {
        if !row.validationIssues.isEmpty {
            return row.validationIssues.map {
                UserDictionaryMessages.text($0.field.rawValue) + ": " + validationReason($0)
            }.joined(separator: "\n")
        }
        guard let problem = row.problem else {
            return ""
        }
        return UserDictionaryMessages.text("importProblem." + problem.rawValue)
    }
}
