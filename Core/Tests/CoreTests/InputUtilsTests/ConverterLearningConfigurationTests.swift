@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
private func withLearningDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("azookey-learning-configuration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func learningOptions(
    _ learningType: LearningType, directory: URL, maxMemoryCount: Int? = nil
) -> ConvertRequestOptions {
    var options = ConvertRequestOptions(
        requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled,
        keyboardLanguage: .ja_JP, learningType: learningType,
        memoryDirectoryURL: directory,
        sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: directory),
        textReplacer: .empty, specialCandidateProviders: [], zenzaiMode: .off, metadata: nil
    )
    if let maxMemoryCount { options.maxMemoryCount = maxMemoryCount }
    return options
}

private func composingText(_ reading: String) -> ComposingText {
    var composingText = ComposingText()
    composingText.insertAtCursorPosition(reading, inputStyle: .direct)
    return composingText
}

@MainActor
@Test func unchangedLearningSettingsSkipMaintenanceConversionAndStillSavePendingHistory() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let candidates = ConverterLearningConfiguration.requestCandidates(
            composingText("きょう"), options: learningOptions(.inputAndOutput, directory: directory),
            converter: converter
        )
        let candidate = try #require(candidates.mainResults.first)
        #expect(!ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
        converter.updateLearningData(candidate)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.louds").path))

        #expect(!ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.louds").path))
    }
}

@MainActor
@Test func privateContextRequiresRestoringLearningBeforeThePublicCandidateIsCommitted() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let publicSession = converter.createSession()
        let privateSession = converter.createSession()
        let candidates = try converter.withSession(publicSession) {
            ConverterLearningConfiguration.requestCandidates(
                composingText("きょう"), options: learningOptions(.inputAndOutput, directory: directory),
                converter: converter
            )
        }
        let candidate = try #require(candidates.mainResults.first)
        _ = try converter.withSession(privateSession) {
            ConverterLearningConfiguration.requestCandidates(
                composingText("あ"), options: learningOptions(.nothing, directory: directory), converter: converter
            )
        }

        #expect(ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
        try converter.withSession(publicSession) { converter.updateLearningData(candidate) }
        converter.commitUpdateLearningData()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.louds").path))
    }
}

@MainActor
@Test func emptyCandidateRequestDoesNotClaimToHaveAppliedItsLearningSettings() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        _ = ConverterLearningConfiguration.requestCandidates(
            composingText("あ"), options: learningOptions(.nothing, directory: directory), converter: converter
        )
        let candidates = ConverterLearningConfiguration.requestCandidates(
            ComposingText(), options: learningOptions(.inputAndOutput, directory: directory), converter: converter
        )
        #expect(candidates.mainResults.isEmpty)
        #expect(ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
    }
}

@MainActor
@Test func changingTheMemoryDirectoryReappliesSettingsBeforeSavingHistory() throws {
    try withLearningDirectory { firstDirectory in
        try withLearningDirectory { secondDirectory in
            let converter = KanaKanjiConverter.withDefaultDictionary()
            let candidates = ConverterLearningConfiguration.requestCandidates(
                composingText("きょう"), options: learningOptions(.inputAndOutput, directory: firstDirectory),
                converter: converter
            )
            let candidate = try #require(candidates.mainResults.first)
            _ = ConverterLearningConfiguration.requestCandidates(
                composingText("あ"), options: learningOptions(.inputAndOutput, directory: secondDirectory),
                converter: converter
            )

            #expect(ConverterLearningConfiguration.apply(
                learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: firstDirectory
            ))
            converter.updateLearningData(candidate)
            converter.commitUpdateLearningData()
            #expect(FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("memory.louds").path))
            #expect(!FileManager.default.fileExists(atPath: secondDirectory.appendingPathComponent("memory.louds").path))
        }
    }
}

@MainActor
@Test func changingTheMemoryLimitRequiresReapplyingTheCommitSettings() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        _ = ConverterLearningConfiguration.requestCandidates(
            composingText("あ"), options: learningOptions(.inputAndOutput, directory: directory, maxMemoryCount: 1),
            converter: converter
        )
        #expect(ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
        #expect(!ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
    }
}

@MainActor
@Test func alternatingConvertersRequiresEachUnknownConfigurationToBeReapplied() throws {
    try withLearningDirectory { directory in
        let first = KanaKanjiConverter.withDefaultDictionary()
        let second = KanaKanjiConverter.withDefaultDictionary()
        for converter in [first, second, first] {
            #expect(ConverterLearningConfiguration.apply(
                learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
            ))
        }
    }
}

@MainActor
@Test func rememberingLearningSettingsDoesNotRetainAClosedConverter() throws {
    try withLearningDirectory { directory in
        weak var previousConverter: KanaKanjiConverter?
        do {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            previousConverter = converter
            #expect(ConverterLearningConfiguration.apply(
                learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
            ))
        }
        #expect(previousConverter == nil)
        let replacement = KanaKanjiConverter.withDefaultDictionary()
        #expect(ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: replacement, memoryDirectoryURL: directory
        ))
    }
}

@MainActor
@Test func resettingHistoryRequiresRestoringLearningBeforeTheNextCommit() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        _ = ConverterLearningConfiguration.requestCandidates(
            composingText("あ"), options: learningOptions(.inputAndOutput, directory: directory), converter: converter
        )
        #expect(ConverterLearningConfiguration.apply(
            learningType: .nothing, converter: converter, memoryDirectoryURL: directory
        ))
        converter.resetMemory()
        #expect(ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
    }
}

@MainActor
@Test func clearingHistoryAloneKeepsTheKnownSettingsAndAllowsNewLearning() throws {
    try withLearningDirectory { directory in
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let candidates = ConverterLearningConfiguration.requestCandidates(
            composingText("きょう"), options: learningOptions(.inputAndOutput, directory: directory), converter: converter
        )
        let candidate = try #require(candidates.mainResults.first)
        let memoryFile = directory.appendingPathComponent("memory.louds").path
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
        #expect(FileManager.default.fileExists(atPath: memoryFile))
        converter.resetMemory()
        #expect(!FileManager.default.fileExists(atPath: memoryFile))

        #expect(!ConverterLearningConfiguration.apply(
            learningType: .inputAndOutput, converter: converter, memoryDirectoryURL: directory
        ))
        converter.updateLearningData(candidate)
        converter.commitUpdateLearningData()
        #expect(FileManager.default.fileExists(atPath: memoryFile))
    }
}
