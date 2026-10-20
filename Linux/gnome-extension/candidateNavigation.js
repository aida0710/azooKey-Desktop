import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {messages} from './candidateMessages.js';
import {attachCandidateAction} from './candidateAccessibility.js';

export class CandidateNavigation {
    constructor({select, changed, preview}) {
        this._select = select;
        this._changed = changed;
        this._preview = preview;
        this.expanded = false;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this._status = new St.Label({x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._status.set_width(1);
        this._header.add_child(this._status);
        this._replaceHeaderButtons();
        this.actor.add_child(this._header);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._rows = new St.BoxLayout({vertical: true});
        this._scroll.set_child(this._rows);
        this.actor.add_child(this._scroll);
    }

    _replaceHeaderButtons() {
        for (const button of [this._toggle, this._previous, this._next])
            button?.destroy();
        this._toggle = this._button(() => {
            this.expanded = !this.expanded;
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

    update(snapshot, {fontSize, listHeight}) {
        const page = snapshot.candidatePage;
        this.actor.visible = (page?.totalCount ?? 0) > 0;
        if (!this.actor.visible) return 0;
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
        this._status.text = messages.position(page.position ?? '—', page.totalCount);
        this._toggle.label = this.expanded ? messages.closeList : messages.openList;
        for (const [button, index, label] of [
            [this._previous, page.previousIndex, messages.previousPage],
            [this._next, page.nextIndex, messages.nextPage]]) {
            button.label = label;
            button.reactive = index !== null && index !== undefined;
            button._selection = button.reactive ? action(index, false) : null;
            button.visible = this.expanded;
        }
        const identity = JSON.stringify([page.items, actionIdentity, snapshot.showCandidateIndex, fontSize]);
        if (identity !== this._identity) {
            this._identity = identity;
            this._rows.destroy_all_children();
            for (const [offset, item] of page.items.entries()) {
                const button = this._button(source => {
                    if (this.expanded && this._identity === identity && source.get_parent() === this._rows)
                        this._select(source._pressedAction ?? source._selection);
                });
                const prefix = snapshot.showCandidateIndex ? `${offset + 1}. ` : '';
                const label = new St.Label({text: prefix + item.text, x_expand: true,
                    x_align: Clutter.ActorAlign.START, style: `font-size: ${fontSize}px;`});
                button.set_child(label);
                button.accessible_name = [item.text, item.reading].filter(Boolean).join('\n');
                button.get_accessible().accessible_description = item.detailDescription ?? '';
                button.connect('notify::hover', () => {
                    if (button.hover && this._identity === identity) this._preview(item);
                });
                this._rows.add_child(button);
            }
        }
        for (const [offset, button] of this._rows.get_children().entries()) {
            const item = page.items[offset];
            button._selection = action(item.index, true);
            button.set_checked(item.index === snapshot.selection);
        }
        const rowHeight = fontSize + 16;
        const height = Math.min(listHeight, page.items.length * rowHeight);
        this._scroll.height = height;
        this._scroll.visible = this.expanded;
        return Math.max(36, fontSize + 16) + (this.expanded ? height : 0);
    }

    collapse() {
        this.expanded = false;
        this._scroll.hide();
        this._replaceHeaderButtons();
        this._actionIdentity = null;
        this._identity = null;
        this._rows.destroy_all_children();
    }

    applyPalette(palette) {
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text};`);
        for (const button of [this._toggle, this._previous, this._next, ...this._rows.get_children()]) {
            const foreground = button.checked ? palette.selectionText : palette.text;
            const background = button.checked ? palette.selection : palette.surface;
            button.set_style(`background-color: ${background}; color: ${foreground};
                background-gradient-direction: none; box-shadow: none;
                border: 1px solid ${palette.border}; padding: 4px 6px; min-height: 0; min-width: 0;`);
        }
    }
}
