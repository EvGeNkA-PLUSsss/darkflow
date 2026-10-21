"""Extract exact geometry (bounding boxes of solid-colour regions) from the
rendered mockups, in logical 390x844 viewBox coordinates.

The renders were produced at 4x the viewBox (density 192 => 2x, then -resize 200%).
So every pixel coordinate found here is divided by SCALE to get logical points.

Run:  python tool/extract_layout.py
"""

from __future__ import annotations

import json
import os
from collections import defaultdict

import numpy as np
from PIL import Image

SCALE = 4.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RENDER = os.path.join(ROOT, "render")

# Colours taken straight out of the SVG sources.
PALETTE = {
    "background": (0x1A, 0x1A, 0x1A),
    "surface": (0x2C, 0x2C, 0x2C),
    "accent": (0x6C, 0x63, 0xFF),
    "muted": (0xB0, 0xB0, 0xB0),
    "track": (0x3A, 0x3A, 0x3A),
    "accent_dark": (0x46, 0x3C, 0xE5),
    "white": (0xFF, 0xFF, 0xFF),
}


def masks(img: np.ndarray) -> dict[str, np.ndarray]:
    h, w, _ = img.shape
    out = {}
    for name, rgb in PALETTE.items():
        m = (
            (img[:, :, 0] == rgb[0])
            & (img[:, :, 1] == rgb[1])
            & (img[:, :, 2] == rgb[2])
        )
        out[name] = m
    return out


def row_runs(mask_row: np.ndarray) -> list[tuple[int, int]]:
    idx = np.flatnonzero(mask_row)
    if idx.size == 0:
        return []
    breaks = np.flatnonzero(np.diff(idx) > 1)
    starts = np.concatenate(([idx[0]], idx[breaks + 1]))
    ends = np.concatenate((idx[breaks], [idx[-1]]))
    return list(zip(starts.tolist(), ends.tolist()))


def rectangles(mask: np.ndarray, min_area: float) -> list[tuple[int, int, int, int]]:
    """Merge horizontal runs across consecutive rows into rectangles."""
    open_rects: list[list[int]] = []  # x0, x1, y0, y1
    done: list[tuple[int, int, int, int]] = []
    for y in range(mask.shape[0]):
        runs = row_runs(mask[y])
        still_open = []
        used = [False] * len(runs)
        for rect in open_rects:
            rx0, rx1, ry0, ry1 = rect
            matched = False
            for i, (s, e) in enumerate(runs):
                if used[i]:
                    continue
                # allow 1px horizontal jitter (anti-aliasing at the edges)
                if s <= rx1 + 1 and e >= rx0 - 1:
                    rect[0] = min(rx0, s)
                    rect[1] = max(rx1, e)
                    rect[3] = y
                    used[i] = True
                    matched = True
                    break
            if matched:
                still_open.append(rect)
            else:
                done.append((rx0, ry0, rx1, ry1))
        for i, (s, e) in enumerate(runs):
            if not used[i]:
                still_open.append([s, e, y, y])
        open_rects = still_open
    done.extend((r[0], r[2], r[1], r[3]) for r in open_rects)

    kept = []
    for x0, y0, x1, y1 in done:
        w = x1 - x0 + 1
        h = y1 - y0 + 1
        if w * h < min_area:
            continue
        kept.append((x0, y0, x1, y1))
    kept.sort(key=lambda r: (r[1], r[0]))
    return kept


def logical(rect: tuple[int, int, int, int]) -> dict:
    x0, y0, x1, y1 = rect
    return {
        "x": round(x0 / SCALE, 1),
        "y": round(y0 / SCALE, 1),
        "w": round((x1 - x0 + 1) / SCALE, 1),
        "h": round((y1 - y0 + 1) / SCALE, 1),
        "right": round((x1 + 1) / SCALE, 1),
        "bottom": round((y1 + 1) / SCALE, 1),
    }


def main() -> None:
    report: dict[str, dict] = {}
    for fname in sorted(os.listdir(RENDER)):
        if not fname.lower().endswith(".png"):
            continue
        path = os.path.join(RENDER, fname)
        img = np.array(Image.open(path).convert("RGB"))
        h, w, _ = img.shape
        entry: dict = {
            "px": f"{w}x{h}",
            "logical": f"{w / SCALE:.0f}x{h / SCALE:.0f}",
            "regions": defaultdict(list),
        }
        for name, mask in masks(img).items():
            for rect in rectangles(mask, min_area=SCALE * SCALE * 12):
                entry["regions"][name].append(logical(rect))
        entry["regions"] = {k: v[:40] for k, v in entry["regions"].items()}
        report[fname[:-4]] = entry

    out = os.path.join(ROOT, "tool", "layout_report.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)

    for screen, entry in report.items():
        print(f"\n=== {screen} ({entry['logical']} logical) ===")
        for colour, rects in entry["regions"].items():
            if colour in ("background", "white"):
                continue
            print(f"  {colour}:")
            for r in rects:
                print(
                    f"    x={r['x']:>6} y={r['y']:>6} "
                    f"w={r['w']:>6} h={r['h']:>6} right={r['right']:>6} bottom={r['bottom']:>6}"
                )
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
