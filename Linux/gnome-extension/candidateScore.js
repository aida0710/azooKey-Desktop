import Clutter from 'gi://Clutter';
import St from 'gi://St';

// Draws Core's score badge in its palette role inside the node's score line.
export function addScoreBadge(canvas, {presentation, frame, metrics, palette}) {
    const label = new St.Label({text: presentation.label, accessible_name: presentation.detailDescription,
        style: `color: ${palette.scoreText}; background-color: ${palette[presentation.role]}; font-size: ${metrics.scoreFontSize}px; text-align: center;`,
        x_align: Clutter.ActorAlign.CENTER});
    // A stage-backed theme node is required before measuring text in St.
    canvas.add_child(label);
    const labelWidth = label.get_preferred_width(-1)[1] + metrics.scoreBadgeHorizontalInset * 2;
    const width = Math.min(frame.width, Math.max(metrics.scoreBadgeMinimumWidth, labelWidth));
    label.set_position(frame.x + (frame.width - width) / 2, frame.y);
    label.set_size(width, frame.height);
    canvas.set_child_above_sibling(label, null);
}
