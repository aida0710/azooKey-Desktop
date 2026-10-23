import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Exact-reading replacements retain dictionary data for ordinary commit and learning.
final class CandidateWordAlternatives {
    // Two choices per word keep both the live tree and conversion work bounded.
    static let alternativesPerWord = 2
    // Covers ordinary sentences while bounding requests after a long paste.
    static let maximumWords = 16
    // Allows three complete rounds of word edits without renumbering earlier choices.
    static let maximumCandidates = maximumWords * alternativesPerWord * 3
    // A small lattice is sufficient for the two displayed alternatives.
    private static let latticeCandidateCount = 3

    struct Alternative {
        let candidate: Candidate
        let tokens: [CandidateTree.Token]
    }

    private(set) var alternatives: [Alternative] = []
    private var cachedCandidates: [[UInt8]: [Candidate]] = [:]
    private var expandedTokens: Set<[CandidateTree.Token]> = []
    private var learningType: LearningType?
    private var referenceCandidate: Candidate?

    func reset() {
        alternatives.removeAll()
        cachedCandidates.removeAll()
        expandedTokens.removeAll()
        referenceCandidate = nil
    }

    func invalidateCache() {
        cachedCandidates.removeAll()
    }

    func beginConversion() {
        alternatives.removeAll()
        expandedTokens.removeAll()
        referenceCandidate = nil
    }

    func tokens(for candidate: Candidate) -> [CandidateTree.Token]? {
        guard !candidate.value.isFinite else {
            return nil
        }
        return alternatives.first { $0.candidate == candidate && $0.candidate.text.utf8.elementsEqual(candidate.text.utf8) }?.tokens
    }

    /// Both the reference and edited candidates must consume the current
    /// conversion target; SegmentsManager checks that before calling here.
    @MainActor
    func append(for source: Candidate, existing: [Candidate], request: Request) {
        let candidate = splitKanaCandidate(source)
        guard alternatives.count < Self.maximumCandidates,
              candidate.inputable, candidate.actions.isEmpty,
              candidate.data.map(\.word).joined().utf8.elementsEqual(candidate.text.utf8) else {
            return
        }
        if learningType != request.options.learningType {
            cachedCandidates.removeAll()
            learningType = request.options.learningType
        }
        let tokens = tokens(for: candidate) ?? candidate.data.map { .init(text: $0.word, reading: $0.ruby) }
        guard expandedTokens.insert(tokens).inserted else {
            return
        }
        if referenceCandidate == nil, tokens.count > 1 {
            referenceCandidate = candidate
        }
        let words = Array(tokens.prefix(Self.maximumWords))
        let readings = Set(words.map { Array($0.reading.utf8) })
        // Cache only this sentence's visible word ranges, never an input history.
        cachedCandidates = cachedCandidates.filter { readings.contains($0.key) }
        var seen = Set(existing.filter { $0.composingCount == candidate.composingCount }.map {
            self.tokens(for: $0) ?? $0.data.map { .init(text: $0.word, reading: $0.ruby) }
        })
        var dataStart = 0
        for (index, word) in words.enumerated() {
            guard let dataEnd = dataEnd(in: candidate, startingAt: dataStart, word: word) else {
                return
            }
            let range = dataStart..<dataEnd
            dataStart = dataEnd
            let replacements = candidates(reading: word.reading, request: request)
                .filter { !$0.text.utf8.elementsEqual(word.text.utf8) }
            for replacement in replacements.prefix(Self.alternativesPerWord) {
                guard alternatives.count < Self.maximumCandidates else {
                    return
                }
                let elements = Array(candidate.data[..<range.lowerBound]) + replacement.data + Array(candidate.data[range.upperBound...])
                let text = elements.map(\.word).joined()
                var replacedTokens = tokens
                replacedTokens[index] = .init(text: replacement.text, reading: word.reading)
                guard seen.insert(replacedTokens).inserted else { continue }
                // The converter has not scored this whole sentence. Nonfinite values
                // already map to an unavailable score in every presentation adapter.
                let combined = Candidate(
                    text: text, value: -.infinity, composingCount: candidate.composingCount,
                    lastMid: range.upperBound == candidate.data.count ? replacement.lastMid : candidate.lastMid,
                    data: elements, isLearningTarget: candidate.isLearningTarget && replacement.isLearningTarget
                )
                alternatives.append(.init(candidate: combined, tokens: replacedTokens))
            }
        }
    }

    private func splitKanaCandidate(_ candidate: Candidate) -> Candidate {
        guard candidate.data.count == 1, let referenceCandidate,
              candidate.data[0].ruby.utf8.elementsEqual(referenceCandidate.data.map(\.ruby).joined().utf8),
              let tokens = CandidateTree.kanaTokens(
                text: candidate.text, segments: referenceCandidate.data.map { .init(text: $0.word, reading: $0.ruby) }) else {
            return candidate
        }
        // Kana fallbacks already use these boundaries in CandidateTree. Keep
        // their dictionary metadata when a later word is edited on that path.
        let elements = tokens.map { token in
            var element = candidate.data[0]
            element.word = token.text
            element.ruby = token.reading
            return element
        }
        return Candidate(text: candidate.text, value: candidate.value, composingCount: candidate.composingCount,
                         lastMid: candidate.lastMid, data: elements, actions: candidate.actions,
                         inputable: candidate.inputable, isLearningTarget: candidate.isLearningTarget)
    }

    struct Request {
        let converter: KanaKanjiConverter
        let options: ConvertRequestOptions
    }

    private func dataEnd(in candidate: Candidate, startingAt start: Int, word: CandidateTree.Token) -> Int? {
        guard !word.reading.isEmpty else {
            return nil
        }
        var reading = ""
        var text = ""
        for index in start..<candidate.data.count {
            reading += candidate.data[index].ruby
            text += candidate.data[index].word
            if reading.utf8.elementsEqual(word.reading.utf8), text.utf8.elementsEqual(word.text.utf8) {
                return index + 1
            }
            if reading.count >= word.reading.count { break }
        }
        return nil
    }

    @MainActor
    private func candidates(reading: String, request: Request) -> [Candidate] {
        let readingKey = Array(reading.utf8)
        if let cached = cachedCandidates[readingKey] {
            return cached
        }
        var composing = ComposingText()
        composing.insertAtCursorPosition(reading, inputStyle: .direct)
        var options = request.options
        options.N_best = Self.latticeCandidateCount
        options.zenzaiMode = .off
        options.requireJapanesePrediction = .disabled
        options.requireEnglishPrediction = .disabled
        options.experimentalZenzaiPredictiveInput = false
        options.typoCorrectionMode = .disabled
        options.specialCandidateProviders = []
        let session = request.converter.createSession()
        defer { request.converter.removeSession(session) }
        let conversion: ConversionResult
        do {
            conversion = try request.converter.withSession(session) {
                request.converter.requestCandidates(composing, options: options)
            }
        } catch {
            preconditionFailure("Word alternative session was removed: \(error)")
        }
        let candidates = conversion.mainResults.filter {
            $0.inputable && $0.actions.isEmpty
                && $0.data.map(\.ruby).joined().utf8.elementsEqual(reading.utf8)
                && $0.data.map(\.word).joined().utf8.elementsEqual($0.text.utf8)
                && composing.isWholeComposingText(composingCount: $0.composingCount)
        }
        cachedCandidates[readingKey] = candidates
        return candidates
    }
}
