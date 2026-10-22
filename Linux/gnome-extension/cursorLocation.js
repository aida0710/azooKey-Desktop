// Geometry contains only rectangles; never pass document text to diagnostics.
export function validCursorLocation(location) {
    return Array.isArray(location) && location.length === 4 &&
        location.every(Number.isFinite) && location[2] >= 0 && location[3] > 0;
}

export function translateCursorLocation(location, windowPosition) {
    if (!validCursorLocation(location) || !windowPosition?.every(Number.isFinite))
        return null;
    return [location[0] + windowPosition[0], location[1] + windowPosition[1],
        location[2], location[3]];
}

export function resolveCursorAnchor({engineLocation, shellLocation, relative, windowPosition}) {
    if (relative) {
        const location = translateCursorLocation(shellLocation, windowPosition);
        if (location) return {location, source: 'wayland-relative', permitsWordAlignment: false};
    }
    if (validCursorLocation(engineLocation))
        return {location: engineLocation, source: 'engine', permitsWordAlignment: true};
    // A relative rectangle has no screen position without its window origin.
    if (!relative && validCursorLocation(shellLocation))
        return {location: shellLocation, source: 'shell', permitsWordAlignment: false};
    return {location: [0, 0, 0, 0], source: 'unavailable', permitsWordAlignment: false};
}

export function candidatePlacement({cursor, bounds, contentWidth, contentHeight,
    detailHeight, aligned, preferredSide = 'below'}) {
    // Keep details legible for a one-character candidate while bounding long rows.
    const minimumWidth = 320;
    const maximumCompactWidth = 760;
    const requiredWidth = Math.max(minimumWidth, contentWidth);
    const width = Math.min(bounds.width,
        aligned ? requiredWidth : Math.min(maximumCompactWidth, requiredWidth));
    const treeHeight = Math.max(1, Math.min(contentHeight, bounds.height - detailHeight));
    const height = Math.min(bounds.height, treeHeight + detailHeight);
    const desiredX = cursor[0] - (aligned ? 12 : 0);
    const fitsBelow = cursor[1] + cursor[3] + height <= bounds.y + bounds.height;
    const fitsAbove = cursor[1] - height >= bounds.y;
    const side = preferredSide === 'above' && fitsAbove || !fitsBelow && fitsAbove ? 'above' : 'below';
    const desiredY = side === 'below' ? cursor[1] + cursor[3] : cursor[1] - height;
    return {
        x: Math.max(bounds.x, Math.min(desiredX, bounds.x + bounds.width - width)),
        y: Math.max(bounds.y, Math.min(desiredY, bounds.y + bounds.height - height)),
        width, height, treeHeight, side,
        // Scrolling a clipped row breaks its alignment with the document.
        permitsAlignment: desiredX >= bounds.x && desiredX + requiredWidth <= bounds.x + bounds.width,
    };
}
