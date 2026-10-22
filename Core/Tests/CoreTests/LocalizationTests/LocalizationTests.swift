@testable import Core
import Testing

@Test func everyReconversionFailureHasMessagesInEveryLanguage() {
    // Linux maps Core's failure raw values to these keys without a fallback.
    for failure in ReconversionSession.Failure.allCases {
        for language in Localization.Language.allCases {
            let key = "reconversion.\(failure.rawValue)"
            #expect(Localization.text(key, language: language) != key, "\(key) is missing in \(language.rawValue)")
        }
    }
}

@Test func explicitLanguageReadsThatLanguagesTable() {
    #expect(Localization.text("support.unknown", language: .japanese) == "未確認")
    #expect(Localization.text("support.unknown", language: .english) == "Not verified")
    #expect(Localization.text("title", language: .english, table: "UserDictionary") == "User dictionary")
}
