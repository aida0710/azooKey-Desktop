import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {attachCandidateAction} from './candidateAccessibility.js';
import {createWrappingLabel} from './candidateText.js';

// Compact spacing leaves the sentence readable without enlarging the popup.
const COMPOSITION_INSET = 8;
const SENTENCE_GAP = 6;
// A long proposal must not scroll its unconverted remainder out of sight.
const REMAINING_HEIGHT_FRACTION = 0.35;

// The selected sentence stays visible while hover explains another candidate below.
export class CandidateComposition {
    constructor(select) {
        this._select = select;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this._title = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._title.set_width(1);
        this._header.add_child(this._title);
        this.actor.add_child(this._header);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._content = new St.BoxLayout({vertical: true});
        this._sentence = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        this._reading = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        this._remaining = createWrappingLabel({x_align: Clutter.ActorAlign.START});
        for (const label of [this._sentence, this._reading]) this._content.add_child(label);
        this._scroll.set_child(this._content);
        this.actor.add_child(this._scroll);
        this._remainingScroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        // ScrollView requires StScrollable; a Label cannot be its direct child.
        this._remainingContent = new St.BoxLayout({vertical: true});
        this._remainingContent.add_child(this._remaining);
        this._remainingScroll.set_child(this._remainingContent);
        this.actor.add_child(this._remainingScroll);
    }

    update(snapshot, {fontSize, width, maximumHeight, palette}) {
        const listing = snapshot.candidateDisplay.list ?? {};
        const identity = JSON.stringify([snapshot.contextId, snapshot.generation, listing.confirmIndex,
            listing.confirmLabel]);
        if (this._identity !== identity) {
            this.retire();
            this._identity = identity;
            if (Number.isInteger(listing.confirmIndex)) this._createConfirm(snapshot, listing);
        }
        this._title.text = listing.title ?? '';
        const sentence = listing.commitText ?? snapshot.preedit ?? '';
        if (sentence !== this._sentence.text) {
            this._sentence.text = sentence;
            this._scroll.get_vadjustment().value = 0;
        }
        this._reading.text = listing.readingText ?? '';
        this._reading.visible = Boolean(listing.readingText);
        const remainingText = listing.remainingText ?? '';
        if (remainingText !== this._remaining.text) {
            this._remaining.text = remainingText;
            this._remainingScroll.get_vadjustment().value = 0;
        }
        this._remaining.visible = Boolean(remainingText);
        this._remainingScroll.visible = Boolean(remainingText);
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text}; padding: ${COMPOSITION_INSET}px;`);
        this._title.set_style(`font-size: ${Math.max(12, fontSize - 4)}px;`);
        this._sentence.set_style(`font-size: ${fontSize + 2}px; font-weight: 600; padding-top: ${SENTENCE_GAP}px;`);
        for (const label of [this._reading, this._remaining])
            label.set_style(`font-size: ${Math.max(14, fontSize - 2)}px; padding-top: 4px;`);
        const innerWidth = Math.max(1, width - COMPOSITION_INSET * 2);
        for (const label of [this._sentence, this._reading, this._remaining]) label.set_width(innerWidth);
        if (this._confirm) this._confirm.set_style(`color: ${palette.selectionText}; background-color: ${palette.selection};
            border: 2px solid ${palette.text}; border-radius: 8px; padding: 4px 12px; min-height: 32px; font-size: ${fontSize}px;`);
        const headerHeight = this._header.get_preferred_height(innerWidth)[1];
        const remainingHeight = remainingText ? Math.min(this._remaining.get_preferred_height(innerWidth)[1],
            maximumHeight * REMAINING_HEIGHT_FRACTION) : 0;
        const contentHeight = this._content.get_preferred_height(innerWidth)[1];
        const textHeight = Math.min(contentHeight,
            Math.max(1, maximumHeight - headerHeight - remainingHeight - COMPOSITION_INSET * 2));
        const height = Math.min(maximumHeight, headerHeight + textHeight + remainingHeight + COMPOSITION_INSET * 2);
        this._scroll.height = textHeight;
        this._remainingScroll.height = remainingHeight;
        this.actor.set_size(width, height);
        return height;
    }

    _createConfirm(snapshot, listing) {
        const button = new St.Button({can_focus: false, reactive: true, label: listing.confirmLabel,
            accessible_name: listing.confirmAccessibleName});
        button.get_accessible().accessible_description = listing.confirmAccessibleDescription;
        const selection = new GLib.Variant('(sibis)',
            ['select', listing.confirmIndex, true, snapshot.generation, snapshot.contextId]);
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
