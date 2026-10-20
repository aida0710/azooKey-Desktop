import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Applies learning settings without replacing an application's conversion session.
@MainActor
public enum ConverterLearningConfiguration {
    private struct AppliedConfiguration {
        weak var converter: KanaKanjiConverter?
        let learningType: LearningType
        let maxMemoryCount: Int
        let memoryDirectoryURL: URL

        init(converter: KanaKanjiConverter, options: ConvertRequestOptions) {
            self.converter = converter
            self.learningType = options.learningType
            self.maxMemoryCount = options.maxMemoryCount
            self.memoryDirectoryURL = options.memoryDirectoryURL
        }

        func matches(converter: KanaKanjiConverter, options: ConvertRequestOptions) -> Bool {
            self.converter === converter && learningType == options.learningType
                && maxMemoryCount == options.maxMemoryCount && memoryDirectoryURL == options.memoryDirectoryURL
        }
    }

    // Settings belong to the converter, not to a composition session. Remember
    // only the last observed converter; alternating converters safely reapply.
    private static var lastAppliedConfiguration: AppliedConfiguration?

    /// All Core candidate requests use this entry so another input context's
    /// settings cannot leave the commit-time check stale.
    static func requestCandidates(
        _ composingText: ComposingText, options: ConvertRequestOptions, converter: KanaKanjiConverter
    ) -> ConversionResult {
        let candidates = converter.requestCandidates(composingText, options: options)
        // The pinned converter returns before applying settings for empty input.
        if !composingText.convertTarget.isEmpty {
            lastAppliedConfiguration = .init(converter: converter, options: options)
        }
        return candidates
    }

    /// Returns whether a maintenance conversion was needed to apply settings.
    @discardableResult
    public static func apply(
        learningType: LearningType,
        converter: KanaKanjiConverter,
        memoryDirectoryURL: URL
    ) -> Bool {
        converter.commitUpdateLearningData()
        let options = ConvertRequestOptions(
            requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: learningType, memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL),
            textReplacer: .empty, specialCandidateProviders: [], zenzaiMode: .off, metadata: nil
        )
        if lastAppliedConfiguration?.matches(converter: converter, options: options) == true {
            return false
        }
        // The pinned converter exposes updateLearningConfig, but LearningConfig
        // has no public initializer. A separate, non-neural request sets it
        // through the public API without altering the displayed candidates.
        let maintenanceSession = converter.createSession()
        defer { converter.removeSession(maintenanceSession) }
        do {
            try converter.withSession(maintenanceSession) {
                var probe = ComposingText()
                probe.insertAtCursorPosition("あ", inputStyle: .direct)
                _ = converter.requestCandidates(probe, options: options)
            }
            lastAppliedConfiguration = .init(converter: converter, options: options)
            return true
        } catch {
            // This method owns the session and removes it only after the request.
            preconditionFailure("Learning configuration lost its maintenance session: \(error)")
        }
    }
}
