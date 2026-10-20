import St from 'gi://St';
import {attachCandidateAction} from './candidateAccessibility.js';
import {messages} from './candidateMessages.js';
import {createWrappingLabel} from './candidateText.js';

export class CandidateDetail {
    constructor({changed, toggleTree}) {
        this._changed = changed;
        this._toggleTree = toggleTree;
        this.expanded = false;
        this.actor = new St.BoxLayout({vertical: true, can_focus: false});
        this._header = new St.BoxLayout();
        this.actor.add_child(this._header);
        this._scroll = new St.ScrollView({can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        const content = new St.BoxLayout({vertical: true});
        this.label = createWrappingLabel({accessible_name: messages.detail});
        content.add_child(this.label);
        this._scroll.set_child(content);
        this.actor.add_child(this._scroll);
    }

    layout({identity, treeExpanded, fontSize, width, maximumHeight}) {
        if (identity !== this._identity) {
            this.retire();
            this._identity = identity;
            this._tree = this._button(() => this._toggleTree());
            this._toggle = this._button(() => { this.expanded = !this.expanded; this._changed(); });
        }
        this._tree.label = treeExpanded ? messages.closeTree : messages.openTree;
        this._toggle.label = this.expanded ? messages.closeDetails : messages.openDetails;
        for (const button of [this._tree, this._toggle])
            button.set_style(`font-size: ${Math.max(12, fontSize - 4)}px; padding: 8px;`);
        this._scroll.visible = this.expanded;
        this.label.set_width(Math.max(1, width - 24));
        this.label.set_style(`font-size: ${fontSize}px; padding: 0 12px 12px;`);
        const headerHeight = this._header.get_preferred_height(width)[1];
        const detailHeight = this.expanded ? Math.min(maximumHeight, this.label.get_preferred_height(width - 24)[1] + 12) : 0;
        this._scroll.height = detailHeight;
        this.actor.set_size(width, headerHeight + detailHeight);
        return headerHeight + detailHeight;
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

    applyPalette(palette) {
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text};
            border-top: 1px solid ${palette.border};`);
    }

    reset() { this.expanded = false; this.retire(); }

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
