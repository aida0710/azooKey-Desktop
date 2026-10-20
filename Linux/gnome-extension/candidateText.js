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
