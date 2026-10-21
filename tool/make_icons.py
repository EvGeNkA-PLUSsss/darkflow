"""Generates DarkFlow's application icons.

The Flutter template ships its own icon on every platform, and shipping a release
with it means the app is recognisable as "a Flutter app" rather than as DarkFlow.
This produces one design at every size each platform needs, from a single source
of truth, so Windows, Android and iOS cannot drift apart.

The mark is an onion ring: the accent ring of the DarkFlow palette on the dark
canvas, with a sender dot inside it. Two shapes and two colours, because an icon
has to read at 16 px in a taskbar and at 1024 px in a store listing, and anything
with detail in it becomes mud at the small end.

Run it again after changing the design:

    python tool/make_icons.py

It rewrites the platform icon files in place. Nothing else in the build reads the
masters, so there is nothing to keep in step by hand.
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

# The palette, taken from lib/src/design/app_colors.dart so the icon and the
# interface agree.
CANVAS = (0x1A, 0x1A, 0x1A, 0xFF)   # AppColors.background
ACCENT = (0x6C, 0x63, 0xFF, 0xFF)   # AppColors.accent
WHITE = (0xFF, 0xFF, 0xFF, 0xFF)

# Supersampling factor. Everything is drawn large and reduced once, which is what
# keeps the ring smooth instead of stair-stepped at 32 px and below.
SS = 8

# Radius of the canvas corner, as a share of the side. Android and iOS mask the
# icon themselves; Windows does not, so the shape has rounded corners of its own.
CORNER = 0.22


def render(size: int) -> Image.Image:
    """One icon at `size` pixels square, in RGBA."""
    big = size * SS
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Rounded-square canvas.
    draw.rounded_rectangle(
        (0, 0, big - 1, big - 1),
        radius=int(big * CORNER),
        fill=CANVAS,
    )

    centre = big / 2
    # Ring: an outer disc in the accent, with the canvas punched back out of the
    # middle. Drawn as two ellipses rather than an arc so the thickness is exact
    # and does not depend on line joins.
    outer = big * 0.34
    thickness = big * 0.085
    draw.ellipse(
        (centre - outer, centre - outer, centre + outer, centre + outer),
        fill=ACCENT,
    )
    inner = outer - thickness
    draw.ellipse(
        (centre - inner, centre - inner, centre + inner, centre + inner),
        fill=CANVAS,
    )

    # The dot: the message at the centre of the ring.
    dot = big * 0.105
    draw.ellipse(
        (centre - dot, centre - dot, centre + dot, centre + dot),
        fill=WHITE,
    )

    return image.resize((size, size), Image.LANCZOS)


def write_png(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    render(size).save(path, format="PNG")
    print(f"  {path.relative_to(ROOT)}  {size}x{size}")


def write_ico(path: Path, sizes: list[int]) -> None:
    """A multi-resolution .ico, which is what Windows wants.

    Pillow can write an .ico from a single image, but it then stores one bitmap and
    Windows scales it, which looks soft in the taskbar. Each size is rendered at
    its own resolution instead and the results are assembled by hand.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = [render(size) for size in sizes]

    # The ICO container: a 6-byte header, then one 16-byte directory entry per
    # image, then the PNG payloads. Windows has accepted PNG-compressed entries
    # since Vista, which is far smaller than a BMP for these sizes.
    import io

    payloads = []
    for frame in frames:
        buffer = io.BytesIO()
        frame.save(buffer, format="PNG")
        payloads.append(buffer.getvalue())

    header = struct.pack("<HHH", 0, 1, len(frames))
    directory = b""
    offset = len(header) + 16 * len(frames)
    for frame, payload in zip(frames, payloads):
        side = frame.width
        directory += struct.pack(
            "<BBBBHHII",
            0 if side >= 256 else side,
            0 if side >= 256 else side,
            0, 0, 1, 32, len(payload), offset,
        )
        offset += len(payload)

    with path.open("wb") as handle:
        handle.write(header)
        handle.write(directory)
        for payload in payloads:
            handle.write(payload)

    print(f"  {path.relative_to(ROOT)}  {', '.join(str(s) for s in sizes)}")


def main() -> None:
    print("Windows")
    write_ico(ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
              [16, 24, 32, 48, 64, 128, 256])

    print("Android")
    # The launcher icon sizes Android asks for, by density bucket.
    for bucket, size in (
        ("mdpi", 48),
        ("hdpi", 72),
        ("xhdpi", 96),
        ("xxhdpi", 144),
        ("xxxhdpi", 192),
    ):
        write_png(
            ROOT / "android" / "app" / "src" / "main" / "res"
            / f"mipmap-{bucket}" / "ic_launcher.png",
            size,
        )

    print("iOS")
    # The full set Xcode expects, named the way the asset catalogue expects.
    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, size in ios_sizes.items():
        write_png(
            ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset" / name,
            size,
        )

    print("macOS")
    for name, size in (
        ("app_icon_16.png", 16),
        ("app_icon_32.png", 32),
        ("app_icon_64.png", 64),
        ("app_icon_128.png", 128),
        ("app_icon_256.png", 256),
        ("app_icon_512.png", 512),
        ("app_icon_1024.png", 1024),
    ):
        write_png(ROOT / "macos" / "Runner" / "Assets.xcassets"
                  / "AppIcon.appiconset" / name, size)

    print("\nDone. Android's adaptive icon and the iOS launch image are unchanged:")
    print("they are separate assets, and the launcher icon above is what is drawn.")


if __name__ == "__main__":
    main()
