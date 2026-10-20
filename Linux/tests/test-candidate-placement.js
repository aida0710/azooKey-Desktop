import {candidatePlacement, translateCursorLocation, validCursorLocation} from '../gnome-extension/candidatePlacement.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
}

// The native GTK Wayland window may move without another engine cursor event.
equal(translateCursorLocation([24, 96, 0, 32], [189, 75]), [213, 171, 0, 32]);
equal(translateCursorLocation([24, 96, 0, 32], [689, 275]), [713, 371, 0, 32]);
equal(validCursorLocation([0, 0, 0, 0]), false);
equal(validCursorLocation([NaN, 0, 0, 24]), false);

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
print('PASS: Wayland translation, moving window, monitor edges, long content, stable side');
