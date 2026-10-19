"""creative.py <posters dir> <icon png> <out dir>: App Store Creative Assets (header, search results, universal).

Posters are the demo libraries' artwork (see shoot.sh), fetched full size from the server, laid out as a
staggered wall behind a center card. Everything important stays in the middle, the safe area every placement keeps.
"""
import glob, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

POSTERS, ICON, OUT = sys.argv[1:4]
SIZES = {"universal": (5244, 2950), "header": (3840, 1646), "search": (3840, 2560)}
NAME, TAGLINE = "Rivulet", "simply your media"
BG = "#070B1E"
FONT = "/Library/Fonts/SF-Pro-Display-Bold.otf"
FONT_TEXT = "/Library/Fonts/SF-Pro-Display-Light.otf"


def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255)
    return mask


def make(W, H):
    canvas = Image.new("RGB", (W, H), BG)
    posters = sorted(glob.glob(f"{POSTERS}/*.jpg"))
    pw = int(min(W * 0.105, H * 0.30)); ph = pw * 3 // 2; gap = int(pw * 0.09); r = int(pw * 0.06)
    cols = W // (pw + gap) + 2
    cache = {}
    for c in range(cols):
        x = c * (pw + gap) - pw // 2
        y = -int(ph * (0.15 + 0.45 * (c % 3) / 2))  # staggered columns
        row = 0
        while y < H:
            p = posters[(c * 4 + row * 2) % len(posters)]; row += 1
            if p not in cache:
                cache[p] = Image.open(p).convert("RGB").resize((pw, ph), Image.LANCZOS)
            canvas.paste(cache[p], (x, y), rounded(cache[p], r))
            y += ph + gap
    # Darken toward the center so the card reads; edges keep the color.
    shade = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shade).ellipse((W / 2 - H * 0.75, H * 0.08, W / 2 + H * 0.75, H * 0.92), fill=255)
    canvas = Image.composite(Image.new("RGB", (W, H), BG), canvas, shade.filter(ImageFilter.GaussianBlur(int(H * 0.10))))
    canvas = Image.blend(canvas, Image.new("RGB", (W, H), BG), 0.35)

    # Center: icon, name, tagline.
    d = ImageDraw.Draw(canvas)
    title = ImageFont.truetype(FONT, int(H * 0.10))
    tag = ImageFont.truetype(FONT_TEXT, int(H * 0.042))
    isz = int(H * 0.22)
    tb = d.textbbox((0, 0), NAME, font=title, anchor="mt")
    gb = d.textbbox((0, 0), TAGLINE, font=tag, anchor="mt")
    gap1, gap2 = int(H * 0.04), int(H * 0.025)
    total = isz + gap1 + (tb[3] - tb[1]) + gap2 + (gb[3] - gb[1])
    y = (H - total) // 2
    icon = Image.open(ICON).convert("RGB").resize((isz, isz), Image.LANCZOS)
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).rounded_rectangle(((W - isz) // 2, y + 20, (W + isz) // 2, y + isz + 20), int(isz * 0.225), fill=160)
    canvas.paste(Image.new("RGB", (W, H), "#000000"), (0, 0), glow.filter(ImageFilter.GaussianBlur(int(isz * 0.12))))
    canvas.paste(icon, ((W - isz) // 2, y), rounded(icon, int(isz * 0.225)))
    y += isz + gap1
    d.text((W // 2, y), NAME, font=title, fill="#FFFFFF", anchor="mt")
    y += tb[3] - tb[1] + gap2
    # Tracked out: PIL has no letter spacing, so place each character.
    track = tag.size * 0.12
    x = W / 2 - (tag.getlength(TAGLINE) + track * (len(TAGLINE) - 1)) / 2
    for ch in TAGLINE:
        d.text((x, y + tag.getmetrics()[0]), ch, font=tag, fill="#C9CEE6", anchor="ls")
        x += tag.getlength(ch) + track
    return canvas


os.makedirs(OUT, exist_ok=True)
for name, (W, H) in SIZES.items():
    make(W, H).save(f"{OUT}/{name}.png")
    print(f"{OUT}/{name}.png")
