"""Draw Core's score badge in its role color without changing its meaning."""
import gi

gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo


def draw_score_badge(context, presentation, frame, *, metrics, theme):
    layout = PangoCairo.create_layout(context)
    font = Pango.FontDescription("Sans")
    font.set_absolute_size(metrics["scoreFontSize"] * Pango.SCALE)
    layout.set_font_description(font)
    layout.set_text(presentation["label"], -1)
    label_width = layout.get_pixel_size()[0] + metrics["scoreBadgeHorizontalInset"] * 2
    badge_width = min(frame["width"], max(metrics["scoreBadgeMinimumWidth"], label_width))
    left = frame["x"] + (frame["width"] - badge_width) / 2
    context.set_source_rgb(*theme.rgb(presentation["role"]))
    context.rectangle(left, frame["y"], badge_width, frame["height"])
    context.fill()
    layout.set_alignment(Pango.Alignment.CENTER)
    layout.set_width(max(1, int(badge_width * Pango.SCALE)))
    context.set_source_rgb(*theme.rgb("scoreText"))
    context.move_to(left, frame["y"] + (frame["height"] - layout.get_pixel_size()[1]) / 2)
    PangoCairo.show_layout(context, layout)
