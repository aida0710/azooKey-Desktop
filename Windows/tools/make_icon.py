"""Draws the text service icons at the sizes Windows uses: あ on a green tile
(Japanese input, also the product icon) and A on a gray tile (input off).

Usage: python3 make_icon.py <あ icon.ico> <A icon.ico>
Needs Pillow and Noto Sans CJK; the generated icons are committed, so this
only runs when they change.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
JAPANESE_FACE_INDEX = 0  # the .ttc's first face is the Japanese one
JAPANESE_TILE = (46, 125, 82, 255)
# The candidate palette's scoreUnknown gray: neutral, and white text stays readable.
ALPHANUMERIC_TILE = (91, 96, 104, 255)
GLYPH_COLOR = (255, 255, 255, 255)
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def draw(size, glyph, tile):
    scale = 4  # draw large and downsample for smooth edges at 16 px
    canvas = size * scale
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    radius = canvas // 5
    draw.rounded_rectangle([0, 0, canvas - 1, canvas - 1], radius=radius, fill=tile)
    font = ImageFont.truetype(FONT_PATH, int(canvas * 0.78), index=JAPANESE_FACE_INDEX)
    left, top, right, bottom = draw.textbbox((0, 0), glyph, font=font)
    x = (canvas - (right - left)) / 2 - left
    y = (canvas - (bottom - top)) / 2 - top
    draw.text((x, y), glyph, font=font, fill=GLYPH_COLOR)
    return image.resize((size, size), Image.LANCZOS)


def save_icon(path, glyph, tile):
    images = [draw(size, glyph, tile) for size in SIZES]
    images[-1].save(path, format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[:-1])


def main():
    save_icon(sys.argv[1], "あ", JAPANESE_TILE)
    save_icon(sys.argv[2], "A", ALPHANUMERIC_TILE)


if __name__ == "__main__":
    main()
