from PIL import Image, ImageDraw, ImageFilter, ImageFont
import sys

# Usage: python3 scripts/make_app_icon.py design/logo.jpg <bold-font.otf> <output-dir>
# Requires Pillow. Writes icon_<size>.png for every macOS app icon size.
# Same artwork as Show My IP, with a "COPY" badge.
SRC, FONT, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
K = 4
S = 1024 * K
LABEL = "COPY"

def base():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    box = (100 * K, 100 * K, 924 * K, 924 * K)
    radius = 185 * K
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 12 * K, box[2], box[3] + 12 * K), radius, fill=(0, 0, 0, 90))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * K)))
    src = Image.open(SRC).convert("RGBA")
    crop = src.crop((110, 100, 1144, 1134)).resize((824 * K, 824 * K), Image.LANCZOS)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer.paste(crop, (box[0], box[1]))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    canvas.paste(layer, (0, 0), mask)
    return canvas

# The badge keeps the right edge, height and corner radius of the "IP" badge and grows to the left to fit the label.
RIGHT, TOP, BOTTOM = 830 * K, 650 * K, 810 * K
PADDING = 46 * K
R = 44 * K
font = ImageFont.truetype(FONT, 100 * K)

def badge(d):
    tb = d.textbbox((0, 0), LABEL, font=font)
    width = tb[2] - tb[0]
    box = (RIGHT - width - 2 * PADDING, TOP, RIGHT, BOTTOM)
    d.rounded_rectangle(box, R, fill=(245, 240, 250, 255), outline=(14, 7, 32, 255), width=10 * K)
    x0, y0, x1, y1 = box
    d.text(((x0 + x1) / 2 - width / 2 - tb[0], (y0 + y1) / 2 - (tb[3] - tb[1]) / 2 - tb[1]), LABEL, font=font,
           fill=(14, 7, 32, 255))

icon = base()
badge(ImageDraw.Draw(icon))
icon = icon.resize((1024, 1024), Image.LANCZOS)
for px in (16, 32, 64, 128, 256, 512, 1024):
    icon.resize((px, px), Image.LANCZOS).save(f"{OUT}/icon_{px}.png")
