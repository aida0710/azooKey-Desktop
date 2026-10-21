import Foundation
import Testing

@testable import Core

@MainActor
@Suite("Candidate visible rows", .serialized)
struct CandidateVisibleRowsTests {
    @Test("表示件数の保存値は5・7・9で未設定と不正値は7になる")
    func storedCountDefaultsToSevenAndRejectsUnsupportedValues() {
        let key = Config.CandidateVisibleRows.key
        let previous = Config.userDefaults.object(forKey: key)
        let previousStandard = UserDefaults.standard.object(forKey: key)
        defer {
            Config.userDefaults.set(previous, forKey: key)
            UserDefaults.standard.set(previousStandard, forKey: key)
        }
        Config.userDefaults.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        let preference = Config.CandidateVisibleRows()
        #expect(preference.value == .seven)
        for value in Config.CandidateVisibleRows.Value.allCases {
            preference.value = value
            #expect(preference.value == value)
            #expect(Config.object(forKey: key) as? Int == value.rawValue)
        }
        let invalidValues: [Any] = [0, 4, 6, 8, 10, "nine", "9", true, 5.5]
        for invalid in invalidValues {
            Config.set(invalid, forKey: key)
            #expect(preference.value == .seven)
        }
    }

    @Test("全設定同期では文字列でなく選択した整数を符号化する")
    func encodedCountUsesAnIntegerAndRejectsValuesOutsideTheChoices() throws {
        for value in Config.CandidateVisibleRows.Value.allCases {
            let encoded = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(Int.self, from: encoded) == value.rawValue)
            #expect(try JSONDecoder().decode(Config.CandidateVisibleRows.Value.self, from: encoded) == value)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Config.CandidateVisibleRows.Value.self, from: Data("6".utf8))
        }
    }
}
