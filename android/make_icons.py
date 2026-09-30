#!/usr/bin/env python3
"""Generate the Android launcher icon (Mage bust on palette blue) from the game sprite.

Outputs into android/res/, which CI copies over love-android's app/src/main/res/:
  drawable-<dpi>/love.png            legacy square icon (pre Android 8)
  drawable-<dpi>/love_foreground.png adaptive icon foreground (108dp canvas)
  drawable-anydpi-v26/love.xml       adaptive icon: blue background + foreground
  values/love_icon.xml               background colour

Usage: python3 android/make_icons.py   (needs Pillow)
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SPRITE = os.path.join(HERE, "..", "src", "assets", "mage", "front.png")
RES = os.path.join(HERE, "res")

# The game's 8-colour palette (same values as BaseUnit's palette shader).
PALETTE = [(0x08, 0x14, 0x1E), (0x0F, 0x2A, 0x3F), (0x20, 0x39, 0x4F), (0xF6, 0xD6, 0xBD),
           (0xC3, 0xA3, 0x8A), (0x99, 0x75, 0x77), (0x81, 0x62, 0x71), (0x4E, 0x49, 0x5F)]
BLUE = PALETTE[2] + (255,)   # #20394F, the UI panel blue
BUST_BOX = (3, 4, 15, 19)    # hat + head + shoulders of front.png (x0, y0, x1, y1)
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

# Adaptive canvas is 108dp; launchers show roughly the central 72dp (18..90).
CANVAS_DP, VISIBLE_DP = 108, 72
BUST_PX_DP = 4.5     # size of one sprite pixel in dp
BUST_BOTTOM_DP = 94  # below the visible area, so the bust is cut by the mask edge


def snap_to_palette(img):
    """Like the in-game shader: every pixel to its nearest palette colour.
    Faint pixels are dropped so the icon edges stay crisp."""
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a < 128:
                px[x, y] = (0, 0, 0, 0)
                continue
            best = min(PALETTE, key=lambda c: (c[0]-r)**2 + (c[1]-g)**2 + (c[2]-b)**2)
            px[x, y] = best + (255,)
    return out


def render(canvas_px, px_scale, bottom_px, background):
    bust = snap_to_palette(Image.open(SPRITE).convert("RGBA").crop(BUST_BOX))
    bust = bust.resize((bust.width * px_scale, bust.height * px_scale), Image.NEAREST)
    img = Image.new("RGBA", (canvas_px, canvas_px), background)
    x = (canvas_px - bust.width) // 2
    img.alpha_composite(bust, (x, bottom_px - bust.height))
    return img


def main():
    for name, d in DENSITIES.items():
        folder = os.path.join(RES, "drawable-" + name)
        os.makedirs(folder, exist_ok=True)
        s = max(1, round(BUST_PX_DP * d))
        fg = render(round(CANVAS_DP * d), s, round(BUST_BOTTOM_DP * d), (0, 0, 0, 0))
        fg.save(os.path.join(folder, "love_foreground.png"))
        # Legacy icon = the visible 72dp window on blue, scaled to 48dp.
        full = render(round(CANVAS_DP * d), s, round(BUST_BOTTOM_DP * d), BLUE)
        m = round((CANVAS_DP - VISIBLE_DP) / 2 * d)
        legacy = full.crop((m, m, full.width - m, full.height - m))
        legacy = legacy.resize((round(48 * d), round(48 * d)), Image.NEAREST)
        legacy.save(os.path.join(folder, "love.png"))

    os.makedirs(os.path.join(RES, "drawable-anydpi-v26"), exist_ok=True)
    with open(os.path.join(RES, "drawable-anydpi-v26", "love.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/love_icon_background"/>\n'
                '    <foreground android:drawable="@drawable/love_foreground"/>\n'
                '</adaptive-icon>\n')
    os.makedirs(os.path.join(RES, "values"), exist_ok=True)
    with open(os.path.join(RES, "values", "love_icon.xml"), "w") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                '    <color name="love_icon_background">#%02X%02X%02X</color>\n'
                '</resources>\n' % BLUE[:3])


if __name__ == "__main__":
    main()
