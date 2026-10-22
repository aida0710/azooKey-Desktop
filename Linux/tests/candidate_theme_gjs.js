// Run with GSETTINGS_BACKEND=memory gjs -m Linux/tests/candidate_theme_gjs.js.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {CandidateTheme, appearanceName, scoreRole} from '../gnome-extension/candidateTheme.js';

if (GLib.getenv('GSETTINGS_BACKEND') !== 'memory')
    throw new Error('Use the memory backend; never modify the running desktop in this test');

function equal(actual, expected) {
    if (actual !== expected) throw new Error(`${actual} !== ${expected}`);
}

let changes = 0;
const theme = new CandidateTheme(() => changes++);
const desktop = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
const accessibility = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
desktop.set_string('gtk-theme', 'Adwaita');
for (const [scheme, contrast, expected] of [
    ['prefer-light', false, 'light'], ['prefer-dark', false, 'dark'],
    ['prefer-light', true, 'highContrastLight'], ['prefer-dark', true, 'highContrastDark'],
]) {
    desktop.set_string('color-scheme', scheme);
    accessibility.set_boolean('high-contrast', contrast);
    equal(theme.mode, expected);
    if (theme.rgb('text').length !== 3) throw new Error('Missing sRGB components');
}
equal(appearanceName({colorScheme: 'default', themeName: 'HighContrastInverse', highContrast: false}), 'highContrastDark');
equal(scoreRole(null), 'scoreUnknown');
equal(scoreRole(74), 'scoreLow');
equal(scoreRole(75), 'scoreHigh');
theme.destroy();
const disconnected = changes;
desktop.set_string('color-scheme', 'prefer-light');
accessibility.set_boolean('high-contrast', false);
equal(changes, disconnected);
print('GNOME appearance observers: four modes, score roles, and disconnect PASS');
