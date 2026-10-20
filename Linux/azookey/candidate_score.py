"""Render the Core-provided score label without changing its meaning."""
import gi

gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo
from .candidate_theme import score_role


SCORE_LINE_HEIGHT = 16
SCORE_FONT_SIZE = 12  # Candidate words retain the larger configured font.
SCORE_MINIMUM_WIDTH = 22  # One digit and the unavailable mark get the same space.
SCORE_HORIZONTAL_INSET = 3


def score_presentation(snapshot, node):
    return node.get("scorePresentation") if snapshot.get("showRelativeScores") else None


def draw_score_badge(context, presentation, frame, *, score, theme):
    x, y, width, height = frame
    layout = PangoCairo.create_layout(context)
    font = Pango.FontDescription("Sans")
    font.set_absolute_size(SCORE_FONT_SIZE * Pango.SCALE)
    layout.set_font_description(font)
    layout.set_text(presentation["label"], -1)
    badge_width = min(width, max(SCORE_MINIMUM_WIDTH, layout.get_pixel_size()[0] + SCORE_HORIZONTAL_INSET * 2))
    left = x + (width - badge_width) / 2
    context.set_source_rgb(*theme.rgb(score_role(score)))
    context.rectangle(left, y + height, badge_width, SCORE_LINE_HEIGHT)
    context.fill()
    layout.set_alignment(Pango.Alignment.CENTER)
    layout.set_width(max(1, int(badge_width * Pango.SCALE)))
    context.set_source_rgb(*theme.rgb("scoreText"))
    context.move_to(left, y + height + (SCORE_LINE_HEIGHT - layout.get_pixel_size()[1]) / 2)
    PangoCairo.show_layout(context, layout)
