"""Measure glyph bounding boxes of the mockup text to infer font sizes.

Text in the SVGs is outlined to paths, so the only way to recover sizes is to
measure the rendered pixels. Cap-height is ~0.70 em and x-height ~0.52 em for
the grotesque used in the mockups.
"""

from __future__ import annotations

import os

import numpy as np
from PIL import Image

SCALE = 4.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDER = os.path.join(ROOT, "render")

COLORS = {
    "surface": (0x2C, 0x2C, 0x2C),
    "accent": (0x6C, 0x63, 0xFF),
    "muted": (0xB0, 0xB0, 0xB0),
    "white": (0xFF, 0xFF, 0xFF),
}

# screen, label, colour, x0, y0, x1, y1  (logical coordinates)
PROBES = [
    ("Login", "DarkFlow (h1)", "white", 100, 185, 300, 265),
    ("Login", "Password (placeholder)", "muted", 55, 330, 210, 370),
    ("Login", "Next (button label)", "white", 160, 405, 240, 445),
    ("Login", "Create account (link)", "accent", 130, 450, 270, 495),
    ("SignUp", "Create Account (h1)", "white", 70, 120, 330, 175),
    ("SignUp", "Name (placeholder)", "muted", 55, 200, 200, 240),
    ("Verification", "Create password (h1)", "white", 60, 115, 340, 165),
    ("Verification", "6-digit hint", "muted", 80, 168, 320, 200),
    ("Chats", "Chats (h1)", "white", 130, 55, 265, 105),
    ("Chats", "Search... (placeholder)", "muted", 60, 128, 200, 155),
    ("Chats", "Alice Johnson (name)", "white", 110, 195, 290, 220),
    ("Chats", "preview text", "muted", 110, 220, 340, 240),
    ("Chats", "12:30 (timestamp)", "muted", 300, 195, 350, 220),
    ("Chat", "peer name (appbar)", "white", 60, 18, 250, 45),
    ("Chat", "Hello! (incoming)", "white", 80, 90, 135, 118),
    ("Chat", "Type message...", "muted", 35, 788, 200, 815),
    ("Profile", "Profile (h1)", "white", 130, 25, 265, 70),
    ("Profile", "Mike (name)", "white", 160, 265, 235, 300),
    ("Profile", "Online (status)", "accent", 160, 303, 235, 330),
    ("Profile", "Copy .onion (row)", "white", 14, 330, 210, 360),
    ("Settings", "Settings (h1)", "white", 130, 55, 265, 100),
    ("Settings", "Notifications (row)", "white", 14, 103, 210, 132),
    ("Tor Bridge Settings", "title (h1)", "white", 70, 38, 320, 75),
    ("Tor Bridge Settings", "subtitle line1", "muted", 40, 78, 350, 100),
    ("Tor Bridge Settings", "Presets (h2)", "white", 18, 135, 110, 165),
    ("Tor Bridge Settings", "obfs4 (chip)", "white", 70, 186, 145, 215),
    ("Tor Bridge Settings", "Enter proxy here", "muted", 32, 296, 220, 325),
    ("Tor Connection", "title (h1)", "white", 35, 38, 360, 75),
    ("Tor Connection", "subtitle", "muted", 60, 78, 335, 103),
    ("Tor Connection", "45% (percent)", "white", 165, 160, 225, 200),
    ("Tor Connection", "step 1 (idle)", "muted", 33, 205, 260, 232),
    ("Tor Connection", "step 2 (active)", "accent", 33, 236, 260, 262),
    ("Tor Connection", "Go to Tor bridge settings", "white", 90, 718, 300, 748),
]


def main() -> None:
    cache: dict[str, np.ndarray] = {}
    print(f"{'screen':<22}{'label':<30}{'colour':<9}{'h':>7}{'cap~':>7}  bbox(logical)")
    for screen, label, colour, x0, y0, x1, y1 in PROBES:
        img = cache.get(screen)
        if img is None:
            img = np.array(Image.open(os.path.join(RENDER, screen + ".png")).convert("RGB"))
            cache[screen] = img
        rgb = COLORS[colour]
        mask = (img[:, :, 0] == rgb[0]) & (img[:, :, 1] == rgb[1]) & (img[:, :, 2] == rgb[2])
        sub = np.zeros_like(mask)
        sub[int(y0 * SCALE):int(y1 * SCALE), int(x0 * SCALE):int(x1 * SCALE)] = True
        sub &= mask
        if not sub.any():
            print(f"{screen:<22}{label:<30}{colour:<9}{'--':>7}{'--':>7}  (nothing found)")
            continue
        rows = np.flatnonzero(sub.any(axis=1))
        cols = np.flatnonzero(sub.any(axis=0))
        h = (rows[-1] - rows[0] + 1) / SCALE
        print(
            f"{screen:<22}{label:<30}{colour:<9}{h:>7.1f}{h / 0.70:>7.1f}  "
            f"x={cols[0] / SCALE:.1f}..{(cols[-1] + 1) / SCALE:.1f} "
            f"y={rows[0] / SCALE:.1f}..{(rows[-1] + 1) / SCALE:.1f}"
        )


if __name__ == "__main__":
    main()
