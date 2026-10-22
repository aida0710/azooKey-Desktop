import KanaKanjiConverterModule

public enum ReconversionReading {
    public static func resolve(_ text: String, dictionary: [Config.UserDictionaryEntry]) -> String? {
        let readings = Set(dictionary.filter { $0.word == text }.map { $0.reading.toHiragana() })
        if readings.count == 1 {
            return readings.first
        }
        let hiragana = text.toHiragana()
        guard !hiragana.isEmpty,
              hiragana.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }) else {
            return nil
        }
        return hiragana
    }
}
