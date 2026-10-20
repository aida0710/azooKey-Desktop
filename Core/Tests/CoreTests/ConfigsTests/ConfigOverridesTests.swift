import Foundation
import Testing

@testable import Core

@MainActor
@Suite struct ConfigOverridesTests {
    private enum Failure: Error { case requested }

    @Test func nestedOverridesRestoreTheOuterScopeAndStoredPreferencesAfterThrowing() throws {
        let original = Config.ZenzaiProfile().value
        let preferences = Config.userDefaults.dictionaryRepresentation() as NSDictionary
        try Config.withOverrides([Config.ZenzaiProfile.key: .string("outer")]) {
            #expect(Config.ZenzaiProfile().value == "outer")
            #expect(throws: Failure.requested) {
                try Config.withOverrides([Config.ZenzaiProfile.key: .string("inner")]) {
                    #expect(Config.ZenzaiProfile().value == "inner")
                    throw Failure.requested
                }
            }
            #expect(Config.ZenzaiProfile().value == "outer")
        }
        #expect(Config.ZenzaiProfile().value == original)
        #expect(Config.userDefaults.dictionaryRepresentation() as NSDictionary == preferences)
    }

    @Test func anIndependentTaskCannotReadAnotherOperationsOverrides() async {
        let original = Config.ZenzaiProfile().value
        let independent = Config.withOverrides([Config.ZenzaiProfile.key: .string("worker-only")]) {
            #expect(Config.ZenzaiProfile().value == "worker-only")
            return Task.detached { Config.ZenzaiProfile().value }
        }
        #expect(await independent.value == original)
        #expect(Config.ZenzaiProfile().value == original)
    }
}
