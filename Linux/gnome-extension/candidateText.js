import Pango from 'gi://Pango';
import St from 'gi://St';

// All sentence views preserve the same Unicode text instead of truncating it.
export function createWrappingLabel(properties) {
    const label = new St.Label(properties);
    label.clutter_text.set_line_wrap(true);
    label.clutter_text.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR);
    label.clutter_text.set_ellipsize(Pango.EllipsizeMode.NONE);
    return label;
}

// Inherit the visible actor's stage and theme before reserving a Japanese text row.
export function candidateLineHeight(fontSize, measurementParent) {
    const label = new St.Label({text: 'あ', style: `font-size: ${fontSize}px;`});
    try {
        measurementParent.add_child(label);
        return Math.ceil(label.get_preferred_height(-1)[1]);
    } finally {
        label.destroy();
    }
}
