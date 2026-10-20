import Clutter from 'gi://Clutter';
import St from 'gi://St';
import {scoreRole} from './candidateTheme.js';

export const SCORE_LINE_HEIGHT = 16;
const SCORE_FONT_SIZE = 12; // Candidate words retain the larger configured font.
const SCORE_MINIMUM_WIDTH = 22; // One digit and the unavailable mark get the same space.
const SCORE_HORIZONTAL_INSET = 3;

export function addScoreBadge(canvas, {node, frame, palette}) {
    const presentation = node.scorePresentation;
    const label = new St.Label({text: presentation.label, accessible_name: presentation.detailDescription,
        style: `color: ${palette.scoreText}; background-color: ${palette[scoreRole(node.relativeScore)]}; font-size: ${SCORE_FONT_SIZE}px; text-align: center;`,
        x_align: Clutter.ActorAlign.CENTER});
    // A stage-backed theme node is required before measuring text in St.
    canvas.add_child(label);
    const width = Math.min(frame.width, Math.max(SCORE_MINIMUM_WIDTH, label.get_preferred_width(-1)[1] + SCORE_HORIZONTAL_INSET * 2));
    label.set_position(frame.x + (frame.width - width) / 2, frame.y + frame.height);
    label.set_size(width, SCORE_LINE_HEIGHT);
}
