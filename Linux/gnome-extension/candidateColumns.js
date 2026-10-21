// Keep the candidate and dictionary readable; exceptionally narrow desktops
// expose both columns through one horizontal viewport instead of shrinking text.
const COLUMN_WIDTHS = {candidateMinimum: 240, candidatePreferred: 320,
    definitionMinimum: 280, definitionPreferred: 340, gap: 10,
    candidateCharacters: 13, definitionCharacters: 16};

export function candidateColumns({availableWidth, fontSize, showsDefinition = true}) {
    const candidatePreferred = Math.min(COLUMN_WIDTHS.candidatePreferred,
        Math.max(COLUMN_WIDTHS.candidateMinimum, fontSize * COLUMN_WIDTHS.candidateCharacters));
    if (!showsDefinition) {
        const viewportWidth = Math.min(Math.max(1, Math.floor(availableWidth)), candidatePreferred);
        return {candidateWidth: candidatePreferred, definitionWidth: 0, contentWidth: candidatePreferred,
            viewportWidth, gap: 0};
    }
    const definitionPreferred = Math.min(COLUMN_WIDTHS.definitionPreferred,
        Math.max(COLUMN_WIDTHS.definitionMinimum, fontSize * COLUMN_WIDTHS.definitionCharacters));
    const minimumWidth = COLUMN_WIDTHS.candidateMinimum + COLUMN_WIDTHS.gap + COLUMN_WIDTHS.definitionMinimum;
    const viewportLimit = Math.max(1, Math.floor(availableWidth));
    const contentWidth = Math.max(minimumWidth,
        Math.floor(Math.min(viewportLimit, candidatePreferred + COLUMN_WIDTHS.gap + definitionPreferred)));
    const extraWidth = contentWidth - minimumWidth;
    const candidateGrowth = candidatePreferred - COLUMN_WIDTHS.candidateMinimum;
    const definitionGrowth = definitionPreferred - COLUMN_WIDTHS.definitionMinimum;
    const totalGrowth = candidateGrowth + definitionGrowth;
    const candidateWidth = COLUMN_WIDTHS.candidateMinimum +
        (totalGrowth > 0 ? Math.floor(extraWidth * candidateGrowth / totalGrowth) : 0);
    return {candidateWidth, definitionWidth: contentWidth - candidateWidth - COLUMN_WIDTHS.gap,
        contentWidth, viewportWidth: Math.min(viewportLimit, contentWidth), gap: COLUMN_WIDTHS.gap};
}
