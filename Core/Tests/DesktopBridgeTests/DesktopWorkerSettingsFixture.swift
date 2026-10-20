import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
enum DesktopWorkerSettingsFixture {
    static func settings() -> DesktopWorkerSettings {
        .init(tree: true, candidateTextSize: .standard, showRelativeScores: true, live: false,
              halfSpace: false, backslash: false, optionDirect: false, inputStyle: .default,
              learning: .nothing, punctuation: .kutenAndToten, profile: "", personalization: .off,
              inferenceLimit: 5, predictiveTyping: false, typoCorrection: false, debug: false,
              aiEnabled: false, transformShortcut: .defaultTransformShortcut, customTable: "")
    }

    @discardableResult
    static func configure(_ worker: inout DesktopReadingWorker, settings: DesktopWorkerSettings,
                          revision: Int = 0) throws -> DesktopReadingWorkerResponse {
        try worker.process(.init(operation: "configure-settings", readingProcessGeneration: worker.readingProcessGeneration,
                                 settingsRevision: revision, settings: settings))
    }

    @discardableResult
    static func configure(_ worker: DesktopCandidateWorker, settings: DesktopWorkerSettings,
                          revision: Int = 0) throws -> DesktopCandidateWorkerResponse {
        try worker.process(.init(operation: "configure-settings", workerGeneration: worker.workerGeneration,
                                 settingsRevision: revision, settings: settings))
    }

    static func focus(_ worker: inout DesktopReadingWorker, context: String = "field") throws -> DesktopReadingContextReference {
        let opened = try worker.process(.init(operation: "open", readingProcessGeneration: worker.readingProcessGeneration, context: context))
        return try #require(worker.process(.init(operation: "focus-in", reference: opened.reference,
                                                surroundings: .init(leftContext: "", rightContext: "", privateInput: false))).reference)
    }

    static func key(_ worker: inout DesktopReadingWorker, reference: DesktopReadingContextReference,
                    code: UInt16 = 0, text: String? = nil, modifiers: KeyEventCore.ModifierFlag = []) throws -> DesktopSnapshot {
        try #require(worker.process(.init(operation: "key", reference: reference,
                                          event: .init(modifierFlags: modifiers, characters: text,
                                                       charactersIgnoringModifiers: text, keyCode: code))).snapshot)
    }
}
