#!/usr/bin/env python3
"""Draws the CodecBlue app icon.

The mark is a waveform that turns into steps: the left half is a smooth sine, the right half is
the same sine quantised to a few levels. That is what a codec does — it takes a continuous curve
and reduces it to something a link can carry — and it is the one idea in this project that can be
drawn in a single gesture.

Everything is drawn at 4x and scaled down, because PIL has no antialiasing for thick polylines
and a jagged icon is worse than no icon.

Usage:
    python3 scripts/make-icon.py            writes Resources/AppIcon.icns and Resources/icon.png
"""

import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

# macOS icons do not fill their canvas: the artwork is a rounded square inset by about 10% on
# each side, so that icons of different apps line up optically in the Dock.
CANVAS = 1024
INSET = 100
SIDE = CANVAS - 2 * INSET
# Big Sur's corner radius, as a fraction of the square's side. Apple's own value.
RADIUS = int(SIDE * 0.2237)

SUPERSAMPLE = 4

# The palette: a deep navy that reads as "night", through to the blue the project is named after.
TOP = (10, 26, 56)
BOTTOM = (32, 108, 255)
GLOW = (86, 156, 255)


def vertical_gradient(size, top, bottom):
    """A linear gradient, drawn one row at a time."""
    gradient = Image.new("RGB", (1, size), top)
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return gradient.resize((size, size), Image.NEAREST)


def squircle_mask(size, radius):
    """A rounded square, antialiased by drawing large and shrinking."""
    big = Image.new("L", (size * 2, size * 2), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, size * 2 - 1, size * 2 - 1), radius=radius * 2, fill=255
    )
    return big.resize((size, size), Image.LANCZOS)


def wave_points(width, height, steps, quantise_from):
    """The waveform: a smooth sine that becomes a staircase partway along.

    The staircase is built as real treads and risers rather than by snapping a fast sine to
    levels: a snapped sine at this width turns into blobs, which is what the first version looked
    like. A tread per half-cycle reads as "quantised" at any size, which is the whole idea — a
    codec takes a continuous curve and reduces it to something a link can carry.
    """
    points = []
    cycles = 1.5
    amplitude = height * 0.34
    split = int(steps * quantise_from)

    def value(t):
        return math.sin(t * cycles * 2 * math.pi - math.pi / 2) * amplitude

    # The smooth half.
    for i in range(split + 1):
        t = i / steps
        points.append((t * width, height / 2 + value(t)))

    # The quantised half: eight treads, each a flat segment, joined by vertical risers.
    treads = 8
    start = quantise_from
    for tread in range(treads):
        t0 = start + (1 - start) * tread / treads
        t1 = start + (1 - start) * (tread + 1) / treads
        # The level is the sine sampled at the middle of the tread, rounded to a coarse grid.
        level = round(value((t0 + t1) / 2) / (amplitude / 2)) * (amplitude / 2)
        y = height / 2 + level
        points.append((t0 * width, y))
        points.append((t1 * width, y))

    return points


def draw_icon(size):
    """The icon at `size` pixels, supersampled internally."""
    s = size * SUPERSAMPLE
    # Work in units of the final canvas so the geometry is written once.
    scale = s / CANVAS

    background = vertical_gradient(s, TOP, BOTTOM).convert("RGBA")

    # A soft radial glow behind the mark, so the middle is not a flat field.
    glow = Image.new("L", (s, s), 0)
    ImageDraw.Draw(glow).ellipse(
        (
            s * 0.20,
            s * 0.16,
            s * 0.80,
            s * 0.84,
        ),
        fill=110,
    )
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.10))
    background = Image.composite(
        Image.new("RGBA", (s, s), GLOW + (255,)), background, glow
    )

    inset = INSET * scale
    side = SIDE * scale
    radius = RADIUS * scale
    mask = squircle_mask(int(side), int(radius))

    icon = Image.new("RGBA", (int(side), int(side)), (0, 0, 0, 0))
    icon.paste(background.crop((int(inset), int(inset), int(inset + side), int(inset + side))),
               (0, 0), mask)

    # The waveform, drawn on its own layer so it can be blurred slightly for a soft edge.
    wave_layer = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(wave_layer)
    margin = side * 0.17
    width = side - 2 * margin
    height = side * 0.52
    points = wave_points(width, height, steps=420, quantise_from=0.52)
    points = [(x + margin, y + (side - height) / 2) for x, y in points]

    stroke = max(int(side * 0.075), 2)
    draw.line(points, fill=(255, 255, 255, 255), width=stroke, joint="curve")
    # Round caps: a thick line with square ends looks cut off.
    for x, y in (points[0], points[-1]):
        r = stroke / 2
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, 255))

    icon = Image.alpha_composite(icon, wave_layer)

    # A thin light rim, the way macOS icons catch light at the top edge.
    rim = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(
        (0, 0, icon.size[0] - 1, icon.size[1] - 1),
        radius=radius,
        outline=(255, 255, 255, 46),
        width=max(int(side * 0.008), 1),
    )
    icon = Image.alpha_composite(icon, rim)

    # Place it on the final canvas with the inset margin.
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    canvas.paste(icon, (int(inset), int(inset)), icon)
    return canvas.resize((size, size), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    resources = os.path.join(root, "Resources")
    os.makedirs(resources, exist_ok=True)

    iconset = os.path.join(root, ".build", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    # The sizes `iconutil` expects, including the @2x variants.
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in sizes:
        image = draw_icon(size)
        image.save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        # @2x entries are the same pixels under a different name.
        if size * 2 <= 1024:
            image2 = draw_icon(size * 2)
            image2.save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))

    icns = os.path.join(resources, "AppIcon.icns")
    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset, "-o", icns], capture_output=True, text=True
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return 1

    # A plain PNG for the README and for anything that wants one.
    draw_icon(512).save(os.path.join(resources, "icon.png"))
    print(f"wrote {icns}")
    print(f"wrote {os.path.join(resources, 'icon.png')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
