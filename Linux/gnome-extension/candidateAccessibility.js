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

// Core composes the announcement; this speaks it once per input context.
export class CandidateAnnouncements {
    constructor(announce) {
        this._announce = announce;
    }

    update(snapshot) {
        const announcement = snapshot.candidateDisplay?.announcement;
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
