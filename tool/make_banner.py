"""Renders the DarkFlow channel banner from the "Concentric Silence" philosophy.

## The idea

The subject is a system that shows nothing: a message leaves no trace, and the
only thing that can honestly be depicted is the *path* it takes. So the picture is
a measurement plate rather than a product shot — concentric boundaries crossed, a
circuit axis with relays, and a band of ticks that reads as a scale. Type is used
twice: a wordmark, and one line of classification. The onion address appears as a
clinical annotation at the periphery, the way a specimen number does on a
scientific plate.

## Craft notes

Everything is drawn at 2x and downsampled, because PIL has no antialiasing for
lines: at 1x, hairlines on a dark ground look like a screen door. The palette is
the application's own (`lib/src/design/app_colors.dart`), so the banner and the
product agree rather than merely resembling each other.

Every element is contained inside the margins. An earlier pass let the outermost
rings and the accented arc run off the canvas, which reads as an accident however
deliberate it was — and the tick band overlapped the rings, which is the one thing
a plate about measurement must not do.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------- tokens

BACKGROUND = (26, 26, 26)          # AppColors.background  #1A1A1A
SURFACE = (44, 44, 44)             # AppColors.surface     #2C2C2C
HAIRLINE = (58, 58, 58)            # AppColors.surfaceHigh #3A3A3A
ACCENT = (108, 99, 255)            # AppColors.accent      #6C63FF
TEXT = (255, 255, 255)             # AppColors.textPrimary
MUTED = (176, 176, 176)            # AppColors.textSecondary
FAINT = (38, 38, 38)               # AppColors.divider     #262626

SCALE = 2
W, H = 1280 * SCALE, 640 * SCALE

MARGIN = 96

# The vertical budget, in 1x pixels. Fixed here so nothing can drift into anything
# else: the wordmark occupies the top, the axis crosses the middle, and the scale
# owns the bottom.
WORDMARK_TOP = 138
CLASSIFICATION_TOP = 258
AXIS_Y = 400
RULE_Y = 508
ANNOTATION_TOP = 528
BAND_TOP = 574
BAND_BOTTOM = 592

RING_CENTRE = (860, AXIS_Y)
RING_RADII = (64, 108, 152)
NODE_X = (600, 740, 880)
ACCENTED_NODE = 1
DESTINATION_X = 1116
DESTINATION_W, DESTINATION_H = 92, 56

ROOT = Path(__file__).resolve().parent.parent
FONT_SEMIBOLD = ROOT / "assets/fonts/Inter-SemiBold.ttf"
FONT_REGULAR = ROOT / "assets/fonts/Inter-Regular.ttf"
FONT_MONO = Path(r"C:\Users\EvGeN\.dsh\skills\canvas-design\canvas-fonts\GeistMono-Regular.ttf")

OUT_BANNER = ROOT / "docs/marketing/banner-1280x640.png"
OUT_AVATAR = ROOT / "docs/marketing/avatar-512.png"


def s(value: float) -> int:
    """Scales a 1x pixel measurement to the working canvas."""
    return int(round(value * SCALE))


def font(path: Path, size: float) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), s(size))


def hairline(draw: ImageDraw.ImageDraw, xy, colour=HAIRLINE, width: float = 1):
    draw.line(xy, fill=colour, width=s(width))


def dot(draw: ImageDraw.ImageDraw, centre, radius: float, colour):
    cx, cy = centre
    r = s(radius)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour)


def tracked_text(draw, origin, text, fnt, fill, tracking):
    """Draws text with extra letter-spacing, which is what makes a small label read as a label."""
    x, y = origin
    for char in text:
        draw.text((x, y), char, font=fnt, fill=fill)
        x += draw.textlength(char, font=fnt) + s(tracking)


def render_banner() -> Image.Image:
    image = Image.new("RGB", (W, H), BACKGROUND)
    draw = ImageDraw.Draw(image)

    axis_y = s(AXIS_Y)
    margin = s(MARGIN)
    ring_cx, ring_cy = s(RING_CENTRE[0]), s(RING_CENTRE[1])

    # ---------------------------------------------------------- concentric layers
    #
    # Drawn first so the axis sits on top of them. Each ring is a boundary the
    # traffic crosses; the weight increases outward, so the accented arc at the
    # outermost layer reads as part of a ring rather than as a floating stroke.
    for radius, colour in zip(RING_RADII, (FAINT, SURFACE, HAIRLINE)):
        r = s(radius)
        draw.ellipse([ring_cx - r, ring_cy - r, ring_cx + r, ring_cy + r], outline=colour, width=s(1))

    # One accented quarter-arc on the outer ring: the single use of the accent in the
    # diagram, and what makes the rings read as measured rather than drawn.
    r = s(RING_RADII[-1])
    draw.arc(
        [ring_cx - r, ring_cy - r, ring_cx + r, ring_cy + r],
        start=-72,
        end=-16,
        fill=ACCENT,
        width=s(2),
    )

    # ---------------------------------------------------------- the circuit axis
    hairline(draw, [(margin, axis_y), (s(DESTINATION_X), axis_y)], HAIRLINE)

    # Relays. Two muted, one accented — the accent marks the hop the picture is
    # about, not the prettiest point on the line.
    for index, x in enumerate(NODE_X):
        accent = index == ACCENTED_NODE
        hairline(
            draw,
            [(s(x), axis_y - s(14)), (s(x), axis_y + s(14))],
            SURFACE,
        )
        dot(draw, (s(x), axis_y), 5 if accent else 4, ACCENT if accent else MUTED)

    # The destination: the onion service, as a boundary rather than an icon.
    half_w, half_h = s(DESTINATION_W / 2), s(DESTINATION_H / 2)
    draw.rounded_rectangle(
        [s(DESTINATION_X) - half_w, axis_y - half_h, s(DESTINATION_X) + half_w, axis_y + half_h],
        radius=s(10),
        outline=HAIRLINE,
        width=s(1),
    )
    dot(draw, (s(DESTINATION_X), axis_y), 3, MUTED)

    # ---------------------------------------------------------- type
    #
    # Two sizes only. The wordmark is architecture; the classification line is read
    # second. Nothing explains itself in a sentence.
    draw.text(
        (margin, s(WORDMARK_TOP)),
        "DarkFlow",
        font=font(FONT_SEMIBOLD, 84),
        fill=TEXT,
    )

    classification = font(FONT_REGULAR, 17)
    tracked_text(draw, (margin, s(CLASSIFICATION_TOP)), "PEER-TO-PEER OVER TOR", classification, MUTED, 3)
    tracked_text(
        draw,
        (margin, s(CLASSIFICATION_TOP + 34)),
        "NO SERVER \u00b7 NO ACCOUNT ON FILE",
        classification,
        MUTED,
        3,
    )

    # ---------------------------------------------------------- annotation and scale
    hairline(draw, [(margin, s(RULE_Y)), (W - margin, s(RULE_Y))], SURFACE)

    draw.text(
        (margin, s(ANNOTATION_TOP)),
        "lp6jqmfp\u2026x6qpdj2kpqd.onion",
        font=font(FONT_MONO, 15),
        fill=(116, 116, 116),
    )

    # The scale. Patient repetition is the whole idea: the band is read as rhythm
    # before it is read as marks. Every tenth tick is longer, and the band owns the
    # bottom strip outright — it does not share space with the diagram.
    tick_step = 8
    x = MARGIN
    index = 0
    while x <= 1280 - MARGIN:
        length = 18 if index % 10 == 0 else 8
        colour = HAIRLINE if index % 10 == 0 else SURFACE
        hairline(
            draw,
            [(s(x), s(BAND_BOTTOM - length)), (s(x), s(BAND_BOTTOM))],
            colour,
        )
        x += tick_step
        index += 1
    hairline(draw, [(margin, s(BAND_BOTTOM)), (W - margin, s(BAND_BOTTOM))], SURFACE)

    return image.resize((1280, 640), Image.LANCZOS)


def render_avatar(side: int = 512) -> Image.Image:
    """The same plate at thumbnail size.

    A wordmark becomes a smudge in a channel list, so the mark is the diagram: the
    rings, one accent arc, and the node at the centre of the circuit.
    """
    work = side * 2
    image = Image.new("RGB", (work, work), BACKGROUND)
    draw = ImageDraw.Draw(image)
    centre = (work // 2, work // 2)

    # Radii as a fraction of the frame. Set as absolute numbers they were drawn on the
    # 2x canvas and then halved by the downscale, which left the mark occupying a
    # third of the frame and reading as a speck in a list of avatars.
    outer = int(work * 0.42)
    middle = int(work * 0.32)
    inner = int(work * 0.22)

    for radius, colour, width in (
        (inner, SURFACE, 3),
        (middle, HAIRLINE, 4),
        (outer, SURFACE, 6),
    ):
        draw.ellipse(
            [centre[0] - radius, centre[1] - radius, centre[0] + radius, centre[1] + radius],
            outline=colour,
            width=width,
        )
    draw.arc(
        [centre[0] - outer, centre[1] - outer, centre[0] + outer, centre[1] + outer],
        start=-72,
        end=-16,
        fill=ACCENT,
        width=9,
    )
    node = int(work * 0.055)
    draw.ellipse(
        [centre[0] - node, centre[1] - node, centre[0] + node, centre[1] + node],
        fill=ACCENT,
    )
    return image.resize((side, side), Image.LANCZOS)


if __name__ == "__main__":
    OUT_BANNER.parent.mkdir(parents=True, exist_ok=True)
    render_banner().save(OUT_BANNER, "PNG", optimize=True)
    render_avatar().save(OUT_AVATAR, "PNG", optimize=True)
    for path in (OUT_BANNER, OUT_AVATAR):
        print(f"wrote {path.relative_to(ROOT)}  {path.stat().st_size / 1024:.0f} KB")
