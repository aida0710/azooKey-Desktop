import {messages} from './candidateMessages.js';

export function attachCandidateAction(button) {
    // St.Button does not register an ATK action in GNOME 46. Cally provides
    // the action without making the actor a keyboard-focus target.
    let active = true;
    button.get_accessible().add_action('click', messages.activate, '', accessible => {
        // Cally dispatches in an idle callback. Never reuse this button for a
        // different generation: a queued action must die with its old actor.
        const actor = accessible.get_object();
        if (active && actor?.is_mapped() && actor.reactive)
            actor.emit('clicked', 1);
    });
    // Cally owns queued action info until finalization. Removing an action
    // here would free that info while an idle callback can still refer to it.
    // The callback obtains its actor from ATK, avoiding a strong actor cycle.
    button.connect('destroy', () => { active = false; });
}

export function candidateAnnouncement(snapshot) {
    if (snapshot.inputState === 'composing' && snapshot.candidateDisplayMode === 'menu' &&
        snapshot.selection == null && snapshot.candidates?.length)
        return messages.available(snapshot.candidates.length);
    if (!['previewing', 'selecting', 'replaceSuggestion'].includes(snapshot.inputState))
        return null;
    const candidate = snapshot.candidates?.find(item => item.index === snapshot.selection);
    const node = snapshot.nodes?.find(item => item.id === snapshot.focusedNode);
    if (!candidate || !node) return null;
    const reading = node.reading || candidate.commitScope?.consumedReading || snapshot.reading;
    const parts = [messages.position(candidate.index + 1, snapshot.candidates.length), node.text];
    if (reading) parts.push(messages.reading(reading));
    const word = snapshot.selectedPath?.indexOf(node.id);
    if (word >= 0 && snapshot.selectedPath.length > 1)
        parts.push(messages.wordPosition(word + 1, snapshot.selectedPath.length));
    if (candidate.text !== node.text) parts.push(messages.commit(candidate.text));
    if (candidate.commitScope?.remainingReading)
        parts.push(messages.remaining(candidate.commitScope.remainingReading));
    return parts.join('。');
}

export class CandidateAnnouncements {
    constructor(announce) {
        this._announce = announce;
    }

    update(snapshot) {
        const announcement = candidateAnnouncement(snapshot);
        if (!announcement) {
            this.reset();
            return;
        }
        const identity = JSON.stringify([snapshot.contextId, announcement]);
        if (identity === this._identity) return;
        this._identity = identity;
        // A checked/name change outside the document's focus is ignored by
        // Orca. A standard announcement keeps both input and AT focus there.
        this._announce(announcement);
    }

    reset() {
        this._identity = null;
    }
}
