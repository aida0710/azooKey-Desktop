import {candidatePlacement, resolveCursorAnchor, translateCursorLocation,
    validCursorLocation} from '../gnome-extension/candidatePlacement.js';

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

const base = {bounds: {x: -1280, y: 32, width: 1280, height: 688},
    contentWidth: 900, contentHeight: 2400, detailHeight: 160, aligned: false};
for (const cursor of [[-1280, 32, 0, 32], [-1, 32, 0, 32],
    [-1280, 688, 0, 32], [-1, 688, 0, 32]]) {
    const placed = candidatePlacement({...base, cursor});
    if (placed.x < -1280 || placed.y < 32 || placed.x + placed.width > 0 ||
        placed.y + placed.height > 720 || placed.treeHeight <= 0)
        throw new Error(`Popup escaped the secondary monitor: ${JSON.stringify(placed)}`);
}
const below = candidatePlacement({...base, cursor: [-1200, 100, 0, 32], contentHeight: 100});
equal([below.x, below.y, below.side], [-1200, 132, 'below']);
const above = candidatePlacement({...base, cursor: [-1200, 600, 0, 32], contentHeight: 100});
equal([above.y, above.side], [340, 'above']);
const stable = candidatePlacement({...base, cursor: [-1200, 400, 0, 32],
    contentHeight: 80, preferredSide: 'above'});
equal([stable.y, stable.side], [160, 'above']);
const narrow = candidatePlacement({...base, cursor: [-50, 300, 0, 32], aligned: true});
equal(narrow.permitsAlignment, false);
const detailAtEdge = candidatePlacement({...base, cursor: [-120, 300, 0, 32],
    contentWidth: 100, aligned: true});
equal(detailAtEdge.permitsAlignment, false);

for (const originX of [-800, 1600]) {
    const alignedAtLeft = {...base, bounds: {x: originX, y: -200, width: 800, height: 600},
        cursor: [originX + 12, -100, 0, 24], aligned: true};
    const overflowing = candidatePlacement({...alignedAtLeft, contentWidth: 1200});
    equal([overflowing.x, overflowing.width, overflowing.permitsAlignment], [originX, 800, false]);
    const fitting = candidatePlacement({...alignedAtLeft, contentWidth: 500});
    equal([fitting.x, fitting.width, fitting.permitsAlignment], [originX, 500, true]);
    const narrowerThanDetails = candidatePlacement({...alignedAtLeft,
        bounds: {...alignedAtLeft.bounds, width: 200}, contentWidth: 100});
    equal([narrowerThanDetails.x, narrowerThanDetails.width, narrowerThanDetails.permitsAlignment],
        [originX, 200, false]);
}
print('PASS: Wayland origins and fallbacks, monitor edges, unclipped alignment, stable side');
