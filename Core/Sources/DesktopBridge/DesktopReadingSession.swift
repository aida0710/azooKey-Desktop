import Core
import Foundation
import KanaKanjiConverterModule

/// Explicit live-OFF prototype of the converter-free input side; not the default bridge.
@MainActor
struct DesktopReadingSession {
    enum Failure: String, Error {
        case unsupportedAction = "unsupported_reading_action"
        case reconversionRequiresCoordinator = "reconversion_requires_coordinator"
    }

    private(set) var composition = CompositionState()
    private var state: InputState = .none
    private var language: InputLanguage = .japanese
    private var generation = 0
    private let japaneseInputStyle: InputStyle

    init(inputStyle: InputStyle = .mapped(id: .defaultRomanToKana)) {
        japaneseInputStyle = inputStyle
    }

    private var inputStyle: InputStyle {
        language == .english ? .direct : japaneseInputStyle
    }

    mutating func key(_ event: KeyEventCore, doubleTap: Bool = false) throws -> DesktopSnapshot {
        guard ReconversionShortcut.resolve(event) == nil else {
            throw Failure.reconversionRequiresCoordinator
        }
        guard !doubleTap || event.keyCode != 102 || composition.isEmpty else {
            throw Failure.unsupportedAction
        }
        // Unsupported actions must leave the entire formal state available for the coordinator.
        var next = self
        let response = try next.applyKey(event)
        self = next
        return response
    }

    mutating func reset(commit: Bool) -> DesktopSnapshot {
        let commits = commit && !composition.isEmpty ? [composition.convertTarget] : []
        composition.stopComposition()
        state = .none
        generation += 1
        return snapshot(commits: commits)
    }

    func snapshot(commits: [String] = []) -> DesktopSnapshot {
        var response = DesktopSnapshot()
        response.commits = commits.filter { !$0.isEmpty }
        response.generation = generation
        response.language = language == .japanese ? "japanese" : "english"
        response.reading = composition.convertTarget
        response.readingCursor = unicodeScalarOffset(in: response.reading, utf16Offset: composition.readingCursorUTF16Offset)
        response.inputState = state.bridgeName
        switch state {
        case .unicodeInput(let codePoint):
            response.preedit = "U+" + codePoint
            response.cursor = response.preedit.unicodeScalars.count
        case .composing:
            response.preedit = response.reading
            response.cursor = response.readingCursor
        default:
            break
        }
        return response
    }

    // Match Core's key interpretation; candidate-dependent actions stay explicit until connected.
    // swiftlint:disable:next cyclomatic_complexity
    private mutating func applyKey(_ event: KeyEventCore) throws -> DesktopSnapshot {
        generation += 1
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(characters: event.characters, modifierFlags: event.modifierFlags,
                                                       inputLanguage: language, inputState: state, typeBackSlash: Config.TypeBackSlash().value) {
            return snapshot(commits: [text])
        }
        let action = UserAction.getUserAction(eventCore: event, inputLanguage: language)
        switch action {
        case .suggest, .transformSelectedText:
            throw Failure.unsupportedAction
        default:
            break
        }
        let (clientAction, callback) = state.event(
            eventCore: event, userAction: action, inputLanguage: language,
            liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: false)
        var commits: [String] = []
        var consumed = true
        switch clientAction {
        case .consume:
            break
        case .fallthrough:
            consumed = false
        case .appendToMarkedText(let text):
            composition.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            composition.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let text):
            commits.append(text)
        case .removeLastMarkedText:
            composition.deleteBackwardFromCursorPosition()
        case .removeNextMarkedText:
            composition.deleteForwardFromCursorPosition()
        case .moveCompositionCursor(let movement):
            composition.moveCursor(movement)
        case .commitMarkedText:
            commits.append(composition.convertTarget)
            composition.stopComposition()
        case .stopComposition:
            composition.stopComposition()
        case .selectInputLanguage(let selectedLanguage):
            language = selectedLanguage
        case .commitMarkedTextAndSelectInputLanguage(let selectedLanguage):
            commits.append(composition.convertTarget)
            composition.stopComposition()
            language = selectedLanguage
        case .submitUnicodeInput(let codePoint):
            if let value = UInt32(codePoint, radix: 16), let scalar = Unicode.Scalar(value) {
                commits.append(String(scalar))
            }
        case .enterUnicodeInputMode, .appendToUnicodeInput, .removeLastUnicodeInput, .cancelUnicodeInput:
            break
        default:
            throw Failure.unsupportedAction
        }
        if consumed {
            applyCallback(callback)
        }
        var response = snapshot(commits: commits)
        response.consumed = consumed
        return response
    }

    private mutating func applyCallback(_ callback: ClientActionCallback) {
        switch callback {
        case .fallthrough:
            break
        case .transition(let next):
            state = next
        case .basedOnBackspace(let empty, let nonempty), .basedOnSubmitCandidate(let empty, let nonempty):
            state = composition.isEmpty ? empty : nonempty
        }
    }
}
