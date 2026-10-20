import Gio from 'gi://Gio';
import {PALETTES} from './candidatePaletteData.js';

export function appearanceName({colorScheme, themeName, highContrast}) {
    const theme = themeName.toLowerCase();
    const dark = colorScheme === 'prefer-dark' ||
        (colorScheme !== 'prefer-light' && (theme.includes('dark') || theme.includes('inverse')));
    const contrast = highContrast || theme.replaceAll('-', '').includes('highcontrast');
    return contrast ? (dark ? 'highContrastDark' : 'highContrastLight') : (dark ? 'dark' : 'light');
}

export function scoreRole(score) {
    if (!Number.isFinite(score)) return 'scoreUnknown';
    // The score remains conditional and relative; retain the existing threshold.
    return score < 75 ? 'scoreLow' : 'scoreHigh';
}

export class CandidateTheme {
    constructor(changed) {
        this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._accessibility = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
        this._connections = [
            [this._interface, this._interface.connect('changed::color-scheme', () => this._refresh(changed))],
            [this._interface, this._interface.connect('changed::gtk-theme', () => this._refresh(changed))],
            [this._accessibility, this._accessibility.connect('changed::high-contrast', () => this._refresh(changed))],
        ];
        this._refresh(() => {});
    }

    _refresh(changed) {
        const mode = appearanceName({
            colorScheme: this._interface.get_string('color-scheme'),
            themeName: this._interface.get_string('gtk-theme'),
            highContrast: this._accessibility.get_boolean('high-contrast'),
        });
        if (mode === this.mode) return;
        this.mode = mode;
        this.palette = PALETTES[mode];
        changed();
    }

    get highContrast() { return this.mode.startsWith('highContrast'); }

    rgb(role) {
        return [1, 3, 5].map(index => parseInt(this.palette[role].slice(index, index + 2), 16) / 255);
    }

    destroy() {
        for (const [settings, connection] of this._connections) settings.disconnect(connection);
        this._connections = [];
    }
}
