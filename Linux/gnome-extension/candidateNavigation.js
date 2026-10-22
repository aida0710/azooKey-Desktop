import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {messages} from './candidateMessages.js';
import {createWrappingLabel} from './candidateText.js';
import {attachCandidateAction} from './candidateAccessibility.js';
import {serializeCandidateIdentity} from './candidateIdentity.js';

// Reduce row whitespace while keeping a 44px target for single-line candidates.
const ROW_VERTICAL_INSET = 5;
const ROW_HORIZONTAL_INSET = 8;
const MINIMUM_CONTENT_HEIGHT = 32;

export class CandidateNavigation {
    constructor({select, changed, preview}) {
        this._select = select;
        this._changed = changed;
        this._preview = preview;
        this.hoveredItem = null;
        this._hoveredButton = null;
        this.expanded = true;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this._status = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._status.set_width(1);
        this._header.add_child(this._status);
        this._replaceHeaderButtons();
        this.actor.add_child(this._header);
        this._hint = new St.Label({text: messages.selectHint});
        this.actor.add_child(this._hint);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._rows = new St.BoxLayout({vertical: true});
        this._scroll.set_child(this._rows);
        this.actor.add_child(this._scroll);
        const adjustment = this._scroll.get_vadjustment();
        for (const property of ['page-size', 'upper'])
            adjustment.connect(`notify::${property}`, () => this._revealSelection());
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
        const listing = snapshot.candidateDisplay.list;
        this.actor.visible = Boolean(listing?.items.length);
        if (!this.actor.visible) {
            this.collapse();
            return 0;
        }
        const actionIdentity = JSON.stringify([
            snapshot.contextId, snapshot.generation, listing.confirmIndex, this.expanded,
            listing.previousIndex, listing.nextIndex,
        ]);
        if (actionIdentity !== this._actionIdentity) {
            this._actionIdentity = actionIdentity;
            this._replaceHeaderButtons();
        }
        const action = (index, submit) => new GLib.Variant('(sibis)',
            ['select', index, submit, snapshot.generation, snapshot.contextId]);
        this._status.text = listing.positionText;
        this._toggle.label = this.expanded ? messages.closeList : messages.openList;
        for (const [button, index, label] of [
            [this._previous, listing.previousIndex, messages.previousPage],
            [this._next, listing.nextIndex, messages.nextPage]]) {
            button.label = label;
            button.reactive = index !== null && index !== undefined;
            button._selection = button.reactive ? action(index, false) : null;
            button.visible = this.expanded;
        }
        // Selection changes keep rows, their scroll position and hover state.
        const items = listing.items.map(({selected, ...item}) => item);
        const pageIdentity = serializeCandidateIdentity([items, snapshot.contextId, fontSize]);
        const identity = JSON.stringify([pageIdentity, actionIdentity]);
        if (identity !== this._identity) {
            // Retire queued AT actions while keeping the same candidate under a stationary pointer.
            const hoveredIndex = this.expanded && pageIdentity === this._pageIdentity ? this.hoveredItem?.index : null;
            this._identity = identity;
            this._pageIdentity = pageIdentity;
            if (hoveredIndex == null) this._clearPreview();
            this._hoveredButton = null;
            this._rows.destroy_all_children();
            for (const item of items) {
                const button = this._button(source => {
                    if (this.expanded && this._identity === identity && source.get_parent() === this._rows)
                        this._select(source._pressedAction ?? source._selection);
                });
                const row = new St.BoxLayout();
                button._numbered = Number.isInteger(item.number);
                if (button._numbered) {
                    const number = new St.Label({text: String(item.number), y_align: Clutter.ActorAlign.START,
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
                button.get_accessible().accessible_description = item.accessibleDescription;
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
            const item = listing.items[offset];
            button._selection = action(item.index, false);
            button._candidateLabel.set_width(Math.max(1, width - (button._numbered ? 84 : 52)));
            button.set_checked(item.selected);
            button._selectionMark.text = item.selected ? '✓' : '';
            // St exposes no selected state, so the name carries it.
            button.accessible_name = [item.accessibleName, item.selected ? messages.selected : null].filter(Boolean).join('\n');
        }
        const revealIdentity = JSON.stringify([snapshot.contextId, listing.items[0].index, listing.confirmIndex]);
        if (revealIdentity !== this._revealIdentity) {
            this._revealIdentity = revealIdentity;
            this._revealPending = true;
        }
        this._hint.set_style(`font-size: ${Math.max(12, fontSize - 4)}px; padding: 3px 8px;`);
        if (palette) this.applyPalette(palette);
        const height = Math.min(listHeight, this._rows.get_preferred_height(width)[1]);
        this._scroll.height = height;
        this._scroll.visible = this.expanded;
        this._revealSelection();
        return this._header.get_preferred_height(width)[1] + this._hint.get_preferred_height(width)[1] +
            (this.expanded ? height : 0);
    }

    _revealSelection() {
        if (!this.expanded || !this._revealPending) return;
        const selected = this._rows.get_children().find(button => button.checked);
        const adjustment = this._scroll.get_vadjustment();
        // Clutter can report a natural height and y=0 before layout. Keep the
        // pending selection until its real allocation arrives.
        if (!selected?.has_allocation() || !(selected.height > 0) || !(adjustment.page_size > 0)) return;
        // StViewport updates its adjustment after allocating the children.
        // Do not finish against the previous page's shorter scroll range.
        if (selected.y + selected.height > adjustment.upper) return;
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
            const foreground = button.checked ? palette.selectionText : palette.text;
            const background = button.checked ? palette.selection : palette.surface;
            button.set_style(`background-color: ${background}; color: ${foreground};
                background-gradient-direction: none; box-shadow: none;
                border: 1px solid ${button.checked ? palette.text : palette.border}; border-radius: 8px;
                padding: ${ROW_VERTICAL_INSET}px ${ROW_HORIZONTAL_INSET}px;
                min-height: ${MINIMUM_CONTENT_HEIGHT}px; min-width: 0;`);
        }
    }
}
