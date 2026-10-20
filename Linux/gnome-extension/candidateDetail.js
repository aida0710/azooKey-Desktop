import Pango from 'gi://Pango';
import St from 'gi://St';
import {messages} from './candidateMessages.js';

export class CandidateDetail {
    constructor() {
        this.actor = new St.ScrollView({
            can_focus: false,
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            style: 'padding: 8px;',
        });
        const content = new St.BoxLayout({vertical: true});
        this.label = new St.Label({accessible_name: messages.detail});
        this.label.clutter_text.set_line_wrap(true);
        this.label.clutter_text.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR);
        this.label.clutter_text.set_ellipsize(Pango.EllipsizeMode.NONE);
        content.add_child(this.label);
        this.actor.set_child(content);
    }

    update({text, fontSize, width}) {
        this.label.set_width(Math.max(1, width - 16));
        this.label.set_style(`font-size: ${fontSize}px;`);
        if (text !== this.label.text) {
            this.label.text = text;
            this.actor.get_vadjustment().value = 0;
        }
    }

    applyPalette(palette) {
        this.actor.set_style(`background-color: ${palette.background}; color: ${palette.text}; padding: 8px;`);
    }

    scrollPage(forward) {
        const adjustment = this.actor.get_vadjustment();
        const step = Math.max(1, adjustment.page_size - 16);
        adjustment.value = Math.max(0, Math.min(adjustment.upper - adjustment.page_size,
            adjustment.value + (forward ? step : -step)));
    }
}
