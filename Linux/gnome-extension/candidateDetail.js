import St from 'gi://St';
import Gio from 'gi://Gio';
import Pango from 'gi://Pango';
import {attachCandidateAction} from './candidateAccessibility.js';
import {messages} from './candidateMessages.js';
import {createWrappingLabel, candidateLineHeight} from './candidateText.js';

// Secondary controls use less padding but retain their action target height.
const DETAILS_INSET = 8;
// Reserve the right column's separator before measuring its wrapped text.
const DETAILS_BORDER_WIDTH = 1;
// Only the first short meaning is visible before the user opens the full entry.
const DEFINITION_SUMMARY_CHARACTERS = 96;
// Keep the word heading and one actual meaning line readable before scrolling.
const MINIMUM_DEFINITION_LINES = 2;
const WORDNET_URL = 'https://bond-lab.github.io/wnja/index.ja.html';

export class CandidateDetail {
    constructor({changed, toggleTree}) {
        this._changed = changed;
        this._toggleTree = toggleTree;
        this.expanded = false;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this.actor.add_child(this._header);
        this._definitionSummary = new St.BoxLayout({vertical: true, can_focus: false});
        this._definitionHeading = this._summaryLine();
        this._definitionPreview = createWrappingLabel({can_focus: false});
        this._definitionSummary.add_child(this._definitionHeading);
        this._definitionSummary.add_child(this._definitionPreview);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._scrollContent = new St.BoxLayout({vertical: true});
        this._scrollContent.add_child(this._definitionSummary);
        this._definitionFull = createWrappingLabel({});
        this._scrollContent.add_child(this._definitionFull);
        this.label = createWrappingLabel({accessible_name: messages.detail});
        this._scrollContent.add_child(this.label);
        this._replaceDefinitionSource();
        this._scroll.set_child(this._scrollContent);
        this.actor.add_child(this._scroll);
    }

    _summaryLine() {
        const label = new St.Label({can_focus: false});
        // A long word stays on one line; its meaning wraps independently below.
        label.clutter_text.set_line_wrap(false);
        label.clutter_text.set_ellipsize(Pango.EllipsizeMode.END);
        return label;
    }

    layout({identity, treeExpanded, fontSize, width, maximumHeight, availableHeight = maximumHeight}) {
        if (identity !== this._identity) {
            this.retire();
            this._identity = identity;
            this._tree = this._button(() => this._toggleTree());
            this._toggle = this._button(() => {
                this.expanded = !this.expanded;
                this._scroll.get_vadjustment().value = 0;
                this._changed();
            });
        }
        this._tree.label = treeExpanded ? messages.closeTree : messages.openTree;
        this._toggle.label = this.expanded ? messages.definitionCloseFull : messages.definitionOpenFull;
        for (const button of [this._tree, this._toggle])
            button.set_style(`font-size: ${Math.max(12, fontSize - 4)}px; padding: 5px 8px; min-height: 34px;`);
        this._scroll.show();
        const contentWidth = Math.max(1, width - DETAILS_BORDER_WIDTH);
        // A large text scale can make the two controls wider than the side
        // column. Stack only its controls; the definition stays to the right.
        this._header.vertical = [this._tree, this._toggle].reduce((sum, button) =>
            sum + Math.ceil(button.get_preferred_width(-1)[1]), 0) > contentWidth;
        const textWidth = Math.max(1, contentWidth - DETAILS_INSET * 2);
        for (const label of [this.label, this._definitionFull]) {
            label.set_width(textWidth);
            label.set_style(`font-size: ${fontSize}px; padding: 0 ${DETAILS_INSET}px ${DETAILS_INSET}px;`);
        }
        this._definitionSummary.set_style(`padding: 0 ${DETAILS_INSET}px;`);
        for (const label of [this._definitionHeading, this._definitionPreview]) {
            label.set_width(textWidth);
            label.set_style(`font-size: ${fontSize}px; padding: 0;`);
            label.show();
        }
        this._definitionSummary.visible = !this.expanded;
        this._definitionFull.visible = this.expanded;
        this.label.visible = this.expanded;
        this._definitionSource.visible = this.expanded && this._definition?.status === 'found';
        this._definitionSource.set_style(`font-size: ${Math.max(12, fontSize - 4)}px; padding: 5px 8px; min-height: 34px;`);
        // Clutter rounds children independently; reserve natural heights upward
        // and allocate whole pixels downward so their sum stays inside the actor.
        const headerHeight = Math.ceil(this._header.get_preferred_height(contentWidth)[1]);
        const maximumPixelHeight = Math.max(0, Math.floor(maximumHeight));
        const availablePixelHeight = Math.max(0, Math.floor(availableHeight));
        const heightBudget = Math.max(headerHeight + candidateLineHeight(fontSize, this.actor) * MINIMUM_DEFINITION_LINES,
            Math.min(availablePixelHeight, maximumPixelHeight));
        const contentBudget = Math.max(0, heightBudget - headerHeight);
        // Both the short meaning and full entry scroll within the right column;
        // opening the dictionary never consumes rows from the candidate list.
        this._definitionSummary.set_width(contentWidth);
        this._scrollContent.set_width(contentWidth);
        const detailHeight = Math.min(contentBudget,
            Math.ceil(this._scrollContent.get_preferred_height(contentWidth)[1]));
        this._scroll.set_size(contentWidth, detailHeight);
        const height = Math.min(heightBudget, headerHeight + detailHeight);
        this.actor.set_size(width, height);
        return height;
    }

    _button(activate) {
        const button = new St.Button({can_focus: false, reactive: true});
        attachCandidateAction(button);
        button.connect('clicked', () => { if (button.get_parent() === this._header && button.is_mapped()) activate(); });
        this._header.add_child(button);
        return button;
    }

    update({text}) {
        if (text !== this.label.text) {
            this.label.text = text;
            this._scroll.get_vadjustment().value = 0;
        }
    }

    _replaceDefinitionSource() {
        this._definitionSource?.destroy();
        const source = new St.Button({can_focus: false, reactive: true, label: messages.definitionSource});
        attachCandidateAction(source);
        source.connect('clicked', () => {
            if (source === this._definitionSource && source.is_mapped() && this._definition?.status === 'found') {
                try { Gio.AppInfo.launch_default_for_uri(WORDNET_URL, null); } catch { /* Explicit source link failed. */ }
            }
        });
        this._definitionSource = source;
        this._scrollContent.add_child(source);
    }

    setWordDefinitions(response) {
        if (response !== this._definition) this._replaceDefinitionSource();
        this._definition = response;
        const heading = this._definitionHeadingText();
        this._definitionHeading.text = (response?.status === 'found' ? `${heading} · ${messages.definitionSourceShort}` : heading)
            .replace(/[\r\n\u2028\u2029]+/g, ' ');
        this._definitionHeading.accessible_name = this._definitionHeading.text;
        const preview = this._definitionPreviewText();
        const characters = Array.from(preview.replace(/[\r\n\u2028\u2029]+/g, ' '));
        this._definitionPreview.text = characters.slice(0, DEFINITION_SUMMARY_CHARACTERS).join('') +
            (characters.length > DEFINITION_SUMMARY_CHARACTERS ? '…' : '');
        // St.Label does not expose AT-SPI Text on every Shell version. Name is
        // the current source text, including the untruncated meaning and its word.
        this._definitionPreview.accessible_name = `${heading}\n${preview}`;
        this._updateFullText();
    }

    _definitionHeadingText() {
        const response = this._definition;
        return response?.word ? messages.definitionWord(response.word, response.reading ?? '') : messages.definitionTitle;
    }

    _definitionPreviewText() {
        const response = this._definition;
        if (!response || response.status === 'noTarget') return messages.definitionChooseWord;
        const states = {loading: messages.definitionLoading, unavailable: messages.definitionUnavailable,
            error: messages.definitionError, notFound: messages.definitionNotFound(response.word ?? '')};
        if (response.status !== 'found') return states[response.status] ?? messages.definitionError;
        return response.senses?.[0]?.definitions?.[0] ?? messages.definitionNotFound(response.word ?? '');
    }

    _definitionFullText() {
        const response = this._definition;
        const heading = this._definitionHeadingText();
        if (!response || response.status !== 'found') return `${heading}\n${this._definitionPreviewText()}`;
        const senses = response.senses ?? [];
        if (!senses.length) return `${heading}\n${messages.definitionNotFound(response.word ?? '')}`;
        const lines = [heading];
        senses.forEach((sense, index) => {
            lines.push(`${index + 1}. ${sense.definitions.join('\n')}`);
            if (sense.examples?.length) lines.push(`${messages.definitionExamples}\n${sense.examples.join('\n')}`);
            if (sense.synonyms?.length) lines.push(`${messages.definitionSynonyms}\n${sense.synonyms.join('、')}`);
        });
        if (response.readingUnspecified) lines.push(messages.definitionReadingNote);
        return [...lines, response.copyright ?? '', WORDNET_URL].filter(Boolean).join('\n');
    }

    _updateFullText() {
        const text = this._definitionFullText();
        // Candidate metadata owns scroll reset; dictionary loading/completion must
        // not move the reader during a redraw or a Suspend of the same candidate.
        if (text !== this._definitionFull.text) this._definitionFull.text = text;
        this._definitionFull.accessible_name = text;
    }

    applyPalette(palette) {
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text};
            border-left: ${DETAILS_BORDER_WIDTH}px solid ${palette.border};`);
    }

    reset() { this.expanded = false; this.setWordDefinitions(null); this.retire(); }

    retire() {
        this._identity = null;
        this._header.destroy_all_children();
        this._tree = this._toggle = null;
    }

    scrollPage(forward) {
        if (!this.expanded) { this.expanded = true; this._changed(); }
        const adjustment = this._scroll.get_vadjustment();
        const step = Math.max(1, adjustment.page_size - 16);
        adjustment.value = Math.max(0, Math.min(adjustment.upper - adjustment.page_size,
            adjustment.value + (forward ? step : -step)));
    }
}
