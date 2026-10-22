import {resolveCursorAnchor, translateCursorLocation,
    validCursorLocation} from '../gnome-extension/cursorLocation.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

// The native GTK Wayland window may move without another engine cursor event.
equal(translateCursorLocation([24, 96, 0, 32], [189, 75]), [213, 171, 0, 32]);
equal(translateCursorLocation([24, 96, 0, 32], [689, 275]), [713, 371, 0, 32]);
equal(validCursorLocation([0, 0, 0, 0]), false);
equal(validCursorLocation([NaN, 0, 0, 24]), false);

const relativeCursor = {shellLocation: [24, 96, 0, 32], relative: true};
const unavailable = {location: [0, 0, 0, 0], source: 'unavailable', permitsWordAlignment: false};
for (const windowPosition of [undefined, null]) {
    // No focus window and no compositor actor both leave the relative origin unknown.
    equal(resolveCursorAnchor({...relativeCursor, windowPosition, engineLocation: [0, 0, 0, 0]}),
        unavailable);
    equal(resolveCursorAnchor({...relativeCursor, windowPosition, engineLocation: [1600, 100, 0, 24]}),
        {location: [1600, 100, 0, 24], source: 'engine', permitsWordAlignment: true});
}
for (const windowPosition of [[-900, -100], [-700, -100], [1600, 200]]) {
    equal(resolveCursorAnchor({...relativeCursor, windowPosition, engineLocation: [100, 100, 0, 24]}),
        {location: [windowPosition[0] + 24, windowPosition[1] + 96, 0, 32],
            source: 'wayland-relative', permitsWordAlignment: false});
}
equal(resolveCursorAnchor({shellLocation: [-800, 100, 0, 24], relative: false}),
    {location: [-800, 100, 0, 24], source: 'shell', permitsWordAlignment: false});
equal(resolveCursorAnchor({shellLocation: [-800, 100, 0, 24], relative: false,
    engineLocation: [1600, 100, 0, 24]}),
    {location: [1600, 100, 0, 24], source: 'engine', permitsWordAlignment: true});
equal(resolveCursorAnchor({shellLocation: null, relative: false}), unavailable);

print('PASS: Wayland origins, engine and shell fallbacks keep the real caret location');
