import Foundation

/// The original place a selected-text result may replace: a fresh selection
/// from a named input target, confirmed by an independent witness.
public struct AITransformationTarget: Sendable {
    public let selection: AITextSelection
    public let witness: AISelectionWitness

    /// nil unless the witness describes the captured selection and the field
    /// still reports exactly that selection after the witness was read.
    public init?(captured: AITextSelection, current: AITextField, witness: AISelectionWitness?) {
        guard let witness, captured.identity != nil, witness.describes(captured),
              !current.isSensitive, let currentSelection = current.currentSelection,
              currentSelection.matches(captured) else {
            return nil
        }
        self.selection = captured
        self.witness = witness
    }

    /// Whether the focused field is the original target. Without a newer
    /// report the same identity is enough to start a fresh witness read; a
    /// newer report must still show the original selection.
    public func isOriginal(_ field: AITextField) -> Bool {
        guard !field.isSensitive, let identity = field.identity,
              AITextSelection.sameIdentity(identity, selection.identity) else {
            return false
        }
        guard field.hasSurroundingUpdate else {
            return true
        }
        return field.currentSelection?.matches(selection) ?? false
    }

    /// The original target, confirmed again by a witness read after focus returned.
    public func matches(_ field: AITextField, witness: AISelectionWitness?) -> Bool {
        guard let witness else {
            return false
        }
        return isOriginal(field) && witness.matches(self.witness)
    }
}
