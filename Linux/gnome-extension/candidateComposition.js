import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {attachCandidateAction} from './candidateAccessibility.js';
import {messages} from './candidateMessages.js';
import {createWrappingLabel} from './candidateText.js';

// The selected sentence stays visible while hover explains another candidate below.
export class CandidateComposition {
    constructor(select) {
        this._select = select;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this._title = new St.Label({text: messages.composition, x_expand: true,
            y_align: Clutter.ActorAlign.CENTER});
        this._title.set_width(1);
        this._header.add_child(this._title);
        this.actor.add_child(this._header);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._content = new St.BoxLayout({vertical: true});
        this._sentence = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        this._reading = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        this._remaining = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        for (const label of [this._sentence, this._reading, this._remaining]) this._content.add_child(label);
        this._scroll.set_child(this._content);
        this.actor.add_child(this._scroll);
    }

    update(snapshot, {fontSize, width, maximumHeight, palette}) {
        const candidate = snapshot.candidates?.find(item => item.index === snapshot.selection);
        const identity = JSON.stringify([snapshot.contextId, snapshot.generation, snapshot.selection]);
        if (this._identity !== identity) {
            this.retire();
            this._identity = identity;
            if (candidate) this._createConfirm(snapshot, candidate);
        }
        const sentence = candidate?.text ?? snapshot.preedit ?? '';
        if (sentence !== this._sentence.text) {
            this._sentence.text = sentence;
            this._scroll.get_vadjustment().value = 0;
        }
        const reading = candidate?.commitScope?.consumedReading ?? snapshot.reading;
        this._reading.text = reading ? messages.reading(reading) : '';
        this._reading.visible = Boolean(reading);
        const remaining = candidate?.commitScope?.remainingReading;
        this._remaining.text = remaining ? messages.remaining(remaining) : '';
        this._remaining.visible = Boolean(remaining);
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text}; padding: 12px;`);
        this._title.set_style(`font-size: ${Math.max(12, fontSize - 4)}px;`);
        this._sentence.set_style(`font-size: ${fontSize + 2}px; font-weight: 600; padding-top: 8px;`);
        for (const label of [this._reading, this._remaining])
            label.set_style(`font-size: ${Math.max(14, fontSize - 2)}px; padding-top: 4px;`);
        for (const label of [this._sentence, this._reading, this._remaining]) label.set_width(Math.max(1, width - 24));
        if (this._confirm) this._confirm.set_style(`color: ${palette.selectionText}; background-color: ${palette.selection};
            border: 2px solid ${palette.text}; border-radius: 8px; padding: 7px 16px; font-size: ${fontSize}px;`);
        const headerHeight = this._header.get_preferred_height(width - 24)[1];
        const contentHeight = this._content.get_preferred_height(width - 24)[1];
        const height = Math.min(maximumHeight, headerHeight + contentHeight + 24);
        this._scroll.height = Math.max(1, height - headerHeight - 24);
        this.actor.set_size(width, height);
        return height;
    }

    _createConfirm(snapshot, candidate) {
        const button = new St.Button({can_focus: false, reactive: true, label: `${messages.submit} ↵`,
            accessible_name: `${messages.submit} ${candidate.text}`});
        const selection = new GLib.Variant('(sibis)',
            ['select', candidate.index, true, snapshot.generation, snapshot.contextId]);
        attachCandidateAction(button);
        button.connect('clicked', () => {
            if (this._confirm !== button || !button.reactive || !button.is_mapped()) return;
            // Keep a second pointer/AT callback from committing twice before Update/Hide arrives.
            button.reactive = false;
            this._select(selection);
        });
        this._confirm = button;
        this._header.add_child(button);
    }

    retire() {
        const previous = this._confirm;
        this._confirm = null;
        this._identity = null;
        previous?.destroy();
    }
}
