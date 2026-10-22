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
