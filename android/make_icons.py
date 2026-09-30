#!/usr/bin/env python3
"""Generate the Android launcher icon (Boney bust on blue) from the game sprite.

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
SPRITE = os.path.join(HERE, "..", "src", "assets", "boney", "front.png")
RES = os.path.join(HERE, "res")

BLUE = (52, 101, 196, 255)
BUST_BOX = (4, 13, 17, 25)   # head + shoulders of front.png (x0, y0, x1, y1)
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

# Adaptive canvas is 108dp; launchers show roughly the central 72dp (18..90).
CANVAS_DP, VISIBLE_DP = 108, 72
BUST_PX_DP = 5.0     # size of one sprite pixel in dp
BUST_BOTTOM_DP = 94  # below the visible area, so the bust is cut by the mask edge


def render(canvas_px, px_scale, bottom_px, background):
    bust = Image.open(SPRITE).convert("RGBA").crop(BUST_BOX)
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
