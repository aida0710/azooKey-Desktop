import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {messages} from './candidateMessages.js';
import {createWrappingLabel, candidateLineHeight} from './candidateText.js';
import {attachCandidateAction} from './candidateAccessibility.js';

const ROW_VERTICAL_INSET = 5;
const ROW_HORIZONTAL_INSET = 8;
const MINIMUM_CONTENT_HEIGHT = 32;
// Conversion rows follow the glyph height; the live tree keeps its own spacing.
const COMPACT_ROW_VERTICAL_INSET = 2;
const COMPACT_MINIMUM_CONTENT_HEIGHT = 24;
const DEFAULT_VISIBLE_ROWS = 7;
const VISIBLE_ROW_CHOICES = [5, 7, 9];
const FOOTER_MINIMUM_CONTENT_HEIGHT = 20;
const FOOTER_VERTICAL_INSET = 2;
const FOOTER_HORIZONTAL_INSET = 6;
const FOOTER_MINIMUM_FONT_SIZE = 12;
const FOOTER_FONT_SIZE_REDUCTION = 6;
// The row border is part of both the visible target and its reserved height.
const ROW_BORDER_WIDTH = 1;

export class CandidateNavigation {
    constructor({select, changed, preview, confirmation = null, compact = false}) {
        this._select = select;
        this._changed = changed;
        this._preview = preview;
        this._compact = compact;
        this.visibleRows = DEFAULT_VISIBLE_ROWS;
        this.hoveredItem = null;
        this._hoveredButton = null;
        this.expanded = true;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this.footer = this._header;
        this._status = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._status.set_width(1);
        this._header.add_child(this._status);
        this._replaceHeaderButtons();
        if (!compact) this.actor.add_child(this._header);
        this._hint = new St.Label({text: messages.selectHint});
        this._hint.visible = !compact;
        this.actor.add_child(this._hint);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._rows = new St.BoxLayout({vertical: true});
        this._scroll.set_child(this._rows);
        this.actor.add_child(this._scroll);
        if (confirmation) this._header.add_child(confirmation);
        if (compact) this.actor.add_child(this._header);
        this._scroll.get_vadjustment().connect('notify::page-size', () => this._viewportChanged());
    }

    minimumRowHeight({fontSize}) {
        const contentHeight = this._compact ? COMPACT_MINIMUM_CONTENT_HEIGHT : MINIMUM_CONTENT_HEIGHT;
        const inset = this._compact ? COMPACT_ROW_VERTICAL_INSET : ROW_VERTICAL_INSET;
        return Math.max(contentHeight, candidateLineHeight(fontSize, this.actor)) +
            inset * 2 + ROW_BORDER_WIDTH * 2;
    }

    _replaceHeaderButtons() {
        for (const button of [this._toggle, this._previous, this._next])
            button?.destroy();
        this._toggle = this._button(() => {
            this.expanded = !this.expanded;
            if (!this.expanded) this._clearPreview();
            this._changed();
        });
        this._previous = this._button(button => this._selectPage(button));
        this._next = this._button(button => this._selectPage(button));
        for (const button of [this._toggle, this._previous, this._next]) this._header.add_child(button);
    }

    _selectPage(button) {
        if (this.expanded) this._select(button._pressedAction ?? button._selection);
    }

    _button(activate) {
        const button = new St.Button({can_focus: false, reactive: true, track_hover: true, style_class: 'button'});
        attachCandidateAction(button);
        button.connect('button-press-event', () => {
            button._pressedAction = button._selection;
            return Clutter.EVENT_PROPAGATE;
        });
        button.connect('clicked', () => {
            activate(button);
            button._pressedAction = null;
        });
        button.connect_after('button-release-event', () => {
            button._pressedAction = null;
            return Clutter.EVENT_PROPAGATE;
        });
        return button;
    }

    update(snapshot, {fontSize, listHeight, width = 400, palette}) {
        this._fontSize = fontSize;
        this.visibleRows = Number.isInteger(snapshot.candidateVisibleRows) &&
            VISIBLE_ROW_CHOICES.includes(snapshot.candidateVisibleRows) ? snapshot.candidateVisibleRows : DEFAULT_VISIBLE_ROWS;
        const page = snapshot.candidatePage;
        this.actor.visible = (page?.totalCount ?? 0) > 0;
        if (!this.actor.visible) {
            this.collapse();
            return 0;
        }
        const actionIdentity = JSON.stringify([
            snapshot.contextId, snapshot.generation, snapshot.selection, this.expanded,
            page.previousIndex, page.nextIndex,
        ]);
        if (actionIdentity !== this._actionIdentity) {
            this._actionIdentity = actionIdentity;
            this._replaceHeaderButtons();
        }
        const action = (index, submit) => new GLib.Variant('(sibis)',
            ['select', index, submit, snapshot.generation, snapshot.contextId]);
        this._status.text = (this._compact ? messages.compactPosition : messages.position)(page.position ?? '—', page.totalCount);
        this._toggle.label = this.expanded ? messages.closeList : messages.openList;
        // A compact conversion list stays open; its footer only pages and commits.
        this._toggle.visible = !this._compact;
        for (const [button, index, label] of [
            [this._previous, page.previousIndex, messages.previousPage],
            [this._next, page.nextIndex, messages.nextPage]]) {
            button.label = this._compact ? (button === this._previous ? messages.previousPageSymbol : messages.nextPageSymbol) : label;
            button.reactive = index !== null && index !== undefined;
            button._selection = button.reactive ? action(index, false) : null;
            button.visible = this.expanded;
            button.accessible_name = label;
        }
        const pageIdentity = JSON.stringify([page.items, snapshot.contextId, snapshot.showCandidateIndex, fontSize]);
        const identity = JSON.stringify([pageIdentity, actionIdentity]);
        if (identity !== this._identity) {
            // Retire queued AT actions while keeping the same candidate under a stationary pointer.
            const hoveredIndex = this.expanded && pageIdentity === this._pageIdentity ? this.hoveredItem?.index : null;
            this._identity = identity;
            this._pageIdentity = pageIdentity;
            if (hoveredIndex == null) this._clearPreview();
            this._hoveredButton = null;
            this._rows.destroy_all_children();
            for (const [offset, item] of page.items.entries()) {
                const button = this._button(source => {
                    if (this.expanded && this._identity === identity && source.get_parent() === this._rows)
                        this._select(source._pressedAction ?? source._selection);
                });
                const row = new St.BoxLayout();
                if (snapshot.showCandidateIndex) {
                    const number = new St.Label({text: String(offset + 1), y_align: Clutter.ActorAlign.START,
                        style: `font-size: ${Math.max(12, fontSize - 4)}px; padding: 3px 8px 0 0;`});
                    row.add_child(number);
                }
                const label = createWrappingLabel({text: item.text, x_expand: true,
                    x_align: Clutter.ActorAlign.START, style: `font-size: ${fontSize}px;`});
                button._candidateLabel = label;
                button.connect('notify::allocation', () => this._revealSelection());
                row.add_child(label);
                button._selectionMark = new St.Label({text: '', y_align: Clutter.ActorAlign.START});
                button._selectionMark.set_width(24);
                row.add_child(button._selectionMark);
                button.set_child(row);
                button.accessible_name = [item.text, item.reading].filter(Boolean).join('\n');
                button.get_accessible().accessible_description = [messages.select, item.detailDescription].filter(Boolean).join('\n');
                button.connect('notify::hover', () => {
                    if (this._identity !== identity || button.get_parent() !== this._rows) return;
                    if (button.hover && this.expanded) {
                        this._hoveredButton = button;
                        this.hoveredItem = item;
                        this._preview(item);
                    } else this._clearPreview(button);
                });
                this._rows.add_child(button);
                if (item.index === hoveredIndex) {
                    this._hoveredButton = button;
                    this.hoveredItem = item;
                }
            }
        }
        for (const [offset, button] of this._rows.get_children().entries()) {
            const item = page.items[offset];
            button._selection = action(item.index, false);
            button._candidateLabel.set_width(Math.max(1, width - (snapshot.showCandidateIndex ? 84 : 52)));
            const selected = item.index === snapshot.selection;
            button.set_checked(selected);
            button._selectionMark.text = selected ? '✓' : '';
            button.accessible_name = [item.text, item.reading, selected ? messages.selected : null].filter(Boolean).join('\n');
        }
        const revealIdentity = JSON.stringify([
            snapshot.contextId, page.start, snapshot.selection, this.visibleRows, fontSize, width,
        ]);
        if (revealIdentity !== this._revealIdentity) {
            this._revealIdentity = revealIdentity;
            this._revealPending = true;
        }
        this._hint.set_style(`font-size: ${Math.max(12, fontSize - 4)}px; padding: 3px 8px;`);
        if (palette) this.applyPalette(palette);
        // Use the shortest real row so wrapped candidates cannot enlarge the
        // viewport past the requested count of ordinary single-line words.
        const visibleRowsHeight = this._compact ? Math.min(...this._rows.get_children()
            .map(row => row.get_preferred_height(width)[1])) * this.visibleRows : Infinity;
        const height = Math.min(listHeight, visibleRowsHeight, this._rows.get_preferred_height(width)[1]);
        this._scroll.height = height;
        this._scroll.visible = this.expanded;
        this._revealSelection();
        return this._header.get_preferred_height(width)[1] +
            (this._hint.visible ? this._hint.get_preferred_height(width)[1] : 0) +
            (this.expanded ? height : 0);
    }

    _viewportChanged() {
        const adjustment = this._scroll.get_vadjustment();
        const previousHeight = this._viewportHeight ?? adjustment.page_size;
        this._viewportHeight = adjustment.page_size;
        const selected = this._rows.get_children().find(button => button.checked);
        // A smaller viewport must not hide a visible selection. Browsing away
        // from it deliberately keeps the user's scroll position instead.
        if (selected && adjustment.page_size < previousHeight && selected.y >= adjustment.value &&
            selected.y + selected.height <= adjustment.value + previousHeight)
            this._revealPending = true;
        this._revealSelection();
    }

    _revealSelection() {
        if (!this.expanded || !this._revealPending) return;
        const selected = this._rows.get_children().find(button => button.checked);
        const adjustment = this._scroll.get_vadjustment();
        if (!selected || !(selected.height > 0) || !(adjustment.page_size > 0)) return;
        let offset = adjustment.value;
        if (selected.y < offset || selected.height > adjustment.page_size) offset = selected.y;
        else if (selected.y + selected.height > offset + adjustment.page_size)
            offset = selected.y + selected.height - adjustment.page_size;
        adjustment.value = Math.max(0, Math.min(offset, adjustment.upper - adjustment.page_size));
        this._revealPending = false;
    }

    collapse() {
        this.expanded = false;
        this._scroll.hide();
        this.retire();
    }

    reset() {
        this.expanded = true;
        this.retire();
    }

    retire({preserveViewport = false} = {}) {
        this._clearPreview();
        for (const button of [this._toggle, this._previous, this._next]) button?.destroy();
        this._toggle = this._previous = this._next = null;
        this._actionIdentity = null;
        this._identity = null;
        this._pageIdentity = null;
        if (!preserveViewport) this._revealIdentity = null;
        this._revealPending = false;
        this._rows.destroy_all_children();
    }

    _clearPreview(button = null) {
        if (this.hoveredItem && (!button || this._hoveredButton === button)) {
            this.hoveredItem = null;
            this._hoveredButton = null;
            this._preview(null);
        }
    }

    applyPalette(palette) {
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text};`);
        for (const button of [this._toggle, this._previous, this._next, ...this._rows.get_children()].filter(Boolean)) {
            const isPlainRow = this._compact && button.get_parent() === this._rows;
            if (this._compact && !isPlainRow) {
                button.set_style(`background-color: transparent; color: ${palette.text};
                    background-gradient-direction: none; box-shadow: none; border: 0; border-radius: 0;
                    padding: ${FOOTER_VERTICAL_INSET}px ${FOOTER_HORIZONTAL_INSET}px; min-height: ${FOOTER_MINIMUM_CONTENT_HEIGHT}px;
                    min-width: 0; font-size: ${Math.max(FOOTER_MINIMUM_FONT_SIZE, this._fontSize - FOOTER_FONT_SIZE_REDUCTION)}px;`);
                continue;
            }
            const foreground = button.checked ? palette.selectionText : palette.text;
            const background = button.checked ? palette.selection : isPlainRow ? 'transparent' : palette.surface;
            const borderColor = button.checked ? palette.text : isPlainRow ? 'transparent' : palette.border;
            button.set_style(`background-color: ${background}; color: ${foreground};
                background-gradient-direction: none; box-shadow: none;
                border: ${ROW_BORDER_WIDTH}px solid ${borderColor}; border-radius: ${isPlainRow ? 4 : 8}px;
                padding: ${isPlainRow ? COMPACT_ROW_VERTICAL_INSET : ROW_VERTICAL_INSET}px ${ROW_HORIZONTAL_INSET}px;
                min-height: ${isPlainRow ? COMPACT_MINIMUM_CONTENT_HEIGHT : MINIMUM_CONTENT_HEIGHT}px; min-width: 0;`);
        }
    }
}
