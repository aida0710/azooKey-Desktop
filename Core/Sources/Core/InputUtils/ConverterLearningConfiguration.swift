import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Applies learning settings without replacing an application's conversion session.
public enum ConverterLearningConfiguration {
    @MainActor
    public static func apply(
        learningType: LearningType,
        converter: KanaKanjiConverter,
        memoryDirectoryURL: URL
    ) {
        converter.commitUpdateLearningData()
        // The pinned converter exposes updateLearningConfig, but LearningConfig
        // has no public initializer. A separate, non-neural request sets it
        // through the public API without altering the displayed candidates.
        let maintenanceSession = converter.createSession()
        defer { converter.removeSession(maintenanceSession) }
        do {
            try converter.withSession(maintenanceSession) {
                var probe = ComposingText()
                probe.insertAtCursorPosition("あ", inputStyle: .direct)
                _ = converter.requestCandidates(probe, options: .init(
                    requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled,
                    keyboardLanguage: .ja_JP,
                    learningType: learningType, memoryDirectoryURL: memoryDirectoryURL,
                    sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL),
                    textReplacer: .empty, specialCandidateProviders: [], zenzaiMode: .off, metadata: nil
                ))
            }
        } catch {
            // This method owns the session and removes it only after the request.
            preconditionFailure("Learning configuration lost its maintenance session: \(error)")
        }
    }
}
