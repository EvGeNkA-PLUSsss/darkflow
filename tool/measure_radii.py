"""Measure corner radii + font sizes of the mockups.

For a rounded rectangle, the topmost scanline of the shape spans
[x0 + r, x1 - r], so the horizontal inset on the first row equals r.
"""

from __future__ import annotations

import os

import numpy as np
from PIL import Image

SCALE = 4.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDER = os.path.join(ROOT, "render")

PALETTE = {
    "surface": (0x2C, 0x2C, 0x2C),
    "accent": (0x6C, 0x63, 0xFF),
    "muted": (0xB0, 0xB0, 0xB0),
    "track": (0x3A, 0x3A, 0x3A),
    "accent_dark": (0x46, 0x3C, 0xE5),
    "white": (0xFF, 0xFF, 0xFF),
    "background": (0x1A, 0x1A, 0x1A),
}

# screen -> (label, colour, x, y) in logical coordinates.
PROBES = [
    ("Login", "password field", "surface", 45, 320),
    ("Login", "Next button", "accent", 45, 394),
    ("SignUp", "Name field", "surface", 45, 190),
    ("SignUp", "Next button", "accent", 45, 342),
    ("Verification", "digit box", "surface", 50, 224),
    ("Verification", "Next button", "accent", 45, 300),
    ("Chats", "search field", "surface", 45, 120),
    ("Chats", "avatar", "accent", 45, 190),
    ("Chats", "FAB", "accent", 327, 772),
    ("Chat", "top bar", "surface", 0, 0),
    ("Chat", "incoming bubble", "surface", 69, 82),
    ("Chat", "outgoing bubble", "accent_dark", 69, 144),
    ("Chat", "voice bubble", "surface", 69, 206),
    ("Chat", "input field", "surface", 16, 777),
    ("Profile", "avatar", "accent", 145, 120),
    ("Profile", "list row", "surface", 0, 317),
    ("Settings", "list row", "surface", 0, 90),
    ("Tor Bridge Settings", "preset button", "surface", 20, 172),
    ("Tor Bridge Settings", "textarea", "surface", 20, 288),
    ("Tor Bridge Settings", "Next button", "accent", 45, 772),
    ("Tor Connection", "progress track", "track", 20, 140),
    ("Tor Connection", "bridge button", "surface", 45, 706),
    ("Tor Connection", "next button", "accent", 45, 772),
    ("Tor Connection", "step dot", "accent", 22, 244),
]


def top_run(mask: np.ndarray, x0: int, y0: int) -> tuple[int, int] | None:
    """First non-empty scanline at or below y0, returned in logical units."""
    for y in range(y0, min(y0 + 40, mask.shape[0])):
        idx = np.flatnonzero(mask[y])
        if idx.size:
            return round(idx[0] / SCALE, 1), round((idx[-1] + 1) / SCALE, 1)
    return None


def bottom_run(mask: np.ndarray, x0: int, y0: int, height_guess: int) -> tuple[int, int] | None:
    for y in range(y0 + height_guess, y0, -1):
        if y >= mask.shape[0]:
            continue
        idx = np.flatnonzero(mask[y])
        if idx.size:
            return round(idx[0] / SCALE, 1), round((idx[-1] + 1) / SCALE, 1)
    return None


def main() -> None:
    cache: dict[str, np.ndarray] = {}
    for screen, label, colour, x, y in PROBES:
        path = os.path.join(RENDER, screen + ".png")
        img = cache.get(screen)
        if img is None:
            img = np.array(Image.open(path).convert("RGB"))
            cache[screen] = img
        rgb = PALETTE[colour]
        mask = (
            (img[:, :, 0] == rgb[0]) & (img[:, :, 1] == rgb[1]) & (img[:, :, 2] == rgb[2])
        )
        # Restrict to a band around the probe so neighbouring shapes do not merge.
        band = np.zeros_like(mask)
        y_from = max(0, int(y * SCALE) - 4)
        y_to = min(mask.shape[0], int(y * SCALE) + int(64 * SCALE))
        band[y_from:y_to, max(0, int(x * SCALE) - 8): min(mask.shape[1], int(x * SCALE) + int(320 * SCALE))] = True
        sub = mask & band
        if not sub.any():
            print(f"{screen:<22} {label:<18} — no pixels for {colour} near ({x},{y})")
            continue
        rows = np.flatnonzero(sub.any(axis=1))
        cols = np.flatnonzero(sub.any(axis=0))
        top = rows[0]
        run = top_run(sub, 0, top)
        left = round(cols[0] / SCALE, 1)
        right = round((cols[-1] + 1) / SCALE, 1)
        bottom = round((rows[-1] + 1) / SCALE, 1)
        top_y = round(top / SCALE, 1)
        radius = None if run is None else round(run[0] - left, 1)
        print(
            f"{screen:<22} {label:<18} {colour:<12} "
            f"y={top_y:<7} h={round(bottom - top_y, 1):<6} x={left:<7} w={round(right - left, 1):<7} r~{radius}"
        )


if __name__ == "__main__":
    main()
