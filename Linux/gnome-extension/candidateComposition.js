import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {attachCandidateAction} from './candidateAccessibility.js';
import {messages} from './candidateMessages.js';
import {createWrappingLabel, candidateLineHeight} from './candidateText.js';

// Compact spacing leaves the sentence readable without enlarging the popup.
const COMPOSITION_INSET = 8;
const SENTENCE_GAP = 6;
const READING_GAP = 4;
// A long proposal must not scroll its unconverted remainder out of sight.
const REMAINING_HEIGHT_FRACTION = 0.35;
// Small text actions keep the candidate footer visually separate from words.
const CONFIRM_LAYOUT = {minimumHeight: 20, verticalInset: 2, horizontalInset: 6, minimumFontSize: 12, fontSizeReduction: 6};

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

    update(snapshot, {fontSize, width, maximumHeight, palette, compact = false}) {
        const candidate = snapshot.candidates?.find(item => item.index === snapshot.selection);
        const enterConfirmsCandidate = ['selecting', 'previewing', 'replaceSuggestion'].includes(snapshot.inputState);
        const identity = JSON.stringify([snapshot.contextId, snapshot.generation, snapshot.selection, enterConfirmsCandidate]);
        if (this._identity !== identity) {
            this.retire();
            this._identity = identity;
            if (candidate) this._createConfirm(snapshot, candidate, enterConfirmsCandidate);
        }
        this._title.text = enterConfirmsCandidate ? messages.composition : messages.proposal;
        this._title.visible = !compact;
        this._scroll.visible = !compact;
        const sentence = candidate?.text ?? snapshot.preedit ?? '';
        if (sentence !== this._sentence.text) {
            this._sentence.text = sentence;
            this._scroll.get_vadjustment().value = 0;
        }
        const reading = candidate?.commitScope?.consumedReading ?? snapshot.reading;
        this._reading.text = reading ? messages.reading(reading) : '';
        this._reading.visible = Boolean(reading);
        const remaining = candidate?.commitScope?.remainingReading;
        const remainingText = remaining ? messages.remaining(remaining) : '';
        if (remainingText !== this._remaining.text) {
            this._remaining.text = remainingText;
            this._remainingScroll.get_vadjustment().value = 0;
        }
        this._remaining.visible = Boolean(remaining);
        this._remainingScroll.visible = Boolean(remaining);
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text}; padding: ${COMPOSITION_INSET}px;`);
        this._title.set_style(`font-size: ${Math.max(12, fontSize - 4)}px;`);
        this._sentence.set_style(`font-size: ${fontSize + 2}px; font-weight: 600; padding-top: ${SENTENCE_GAP}px;`);
        const readingFontSize = Math.max(14, fontSize - 2);
        for (const label of [this._reading, this._remaining])
            label.set_style(`font-size: ${readingFontSize}px; padding-top: ${READING_GAP}px;`);
        const innerWidth = Math.max(1, width - COMPOSITION_INSET * 2);
        for (const label of [this._sentence, this._reading, this._remaining]) label.set_width(innerWidth);
        if (this._confirm) this._confirm.set_style(`color: ${palette.text}; background-color: transparent;
            background-gradient-direction: none; box-shadow: none; border: 0; border-radius: 0;
            padding: ${CONFIRM_LAYOUT.verticalInset}px ${CONFIRM_LAYOUT.horizontalInset}px;
            min-height: ${CONFIRM_LAYOUT.minimumHeight}px;
            font-size: ${Math.max(CONFIRM_LAYOUT.minimumFontSize, fontSize - CONFIRM_LAYOUT.fontSizeReduction)}px;`);
        if (compact) {
            // The document already shows the proposal. Keep its explicit commit
            // action in the candidate footer rather than repeating the sentence.
            this.actor.set_style('padding: 0;');
            this._remainingScroll.hide();
            this._scroll.height = 0;
            this._remainingScroll.height = 0;
            const buttonWidth = Math.ceil(this._header.get_preferred_width(-1)[1]);
            const buttonHeight = Math.ceil(this._header.get_preferred_height(buttonWidth)[1]);
            this.actor.set_size(buttonWidth, buttonHeight);
            return buttonHeight;
        }
        const headerHeight = Math.ceil(this._header.get_preferred_height(innerWidth)[1]);
        const minimumTextHeight = candidateLineHeight(fontSize + 2, this.actor) + SENTENCE_GAP;
        const minimumRemainingHeight = remaining ? candidateLineHeight(readingFontSize, this.actor) + READING_GAP : 0;
        const fixedHeight = headerHeight + COMPOSITION_INSET * 2;
        // A short work area scrolls the whole card; clipping its fixed header or
        // the first sentence/remainder line would make those controls unreadable.
        const heightBudget = Math.max(fixedHeight + minimumTextHeight + minimumRemainingHeight,
            Math.max(0, Math.floor(maximumHeight)));
        const contentBudget = heightBudget - fixedHeight;
        const remainingBudget = Math.min(contentBudget - minimumTextHeight,
            Math.max(minimumRemainingHeight, Math.floor(heightBudget * REMAINING_HEIGHT_FRACTION)));
        const remainingHeight = remaining ? Math.min(remainingBudget,
            Math.max(minimumRemainingHeight, Math.ceil(this._remaining.get_preferred_height(innerWidth)[1]))) : 0;
        const contentHeight = Math.max(minimumTextHeight, Math.ceil(this._content.get_preferred_height(innerWidth)[1]));
        const textHeight = Math.min(contentHeight, contentBudget - remainingHeight);
        const height = fixedHeight + textHeight + remainingHeight;
        this._scroll.height = textHeight;
        this._remainingScroll.height = remainingHeight;
        this.actor.set_size(width, height);
        return height;
    }

    _createConfirm(snapshot, candidate, enterConfirmsCandidate) {
        const label = enterConfirmsCandidate ? `${messages.submit} ↵` : messages.submitCandidate;
        const button = new St.Button({can_focus: false, reactive: true, label,
            accessible_name: `${enterConfirmsCandidate ? messages.submit : messages.submitCandidate} ${candidate.text}`});
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
