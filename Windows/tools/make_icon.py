"""Draws the text service icon (あ on a green tile) at the sizes Windows uses.

Usage: python3 make_icon.py <output.ico>
Needs Pillow and Noto Sans CJK; the generated .ico is committed, so this only
runs when the icon changes.
"""
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
JAPANESE_FACE_INDEX = 0  # the .ttc's first face is the Japanese one
TILE_COLOR = (46, 125, 82, 255)
GLYPH_COLOR = (255, 255, 255, 255)
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def draw(size):
    scale = 4  # draw large and downsample for smooth edges at 16 px
    canvas = size * scale
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    radius = canvas // 5
    draw.rounded_rectangle([0, 0, canvas - 1, canvas - 1], radius=radius, fill=TILE_COLOR)
    font = ImageFont.truetype(FONT_PATH, int(canvas * 0.78), index=JAPANESE_FACE_INDEX)
    left, top, right, bottom = draw.textbbox((0, 0), "あ", font=font)
    x = (canvas - (right - left)) / 2 - left
    y = (canvas - (bottom - top)) / 2 - top
    draw.text((x, y), "あ", font=font, fill=GLYPH_COLOR)
    return image.resize((size, size), Image.LANCZOS)


def main():
    images = [draw(size) for size in SIZES]
    images[-1].save(sys.argv[1], format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[:-1])


if __name__ == "__main__":
    main()
