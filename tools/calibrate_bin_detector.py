#!/usr/bin/env python3
"""Extract YUV percentiles from bin-colored pixels in reference photos."""
from __future__ import annotations

import statistics
from pathlib import Path

from PIL import Image


def rgb_to_yuv(r: float, g: float, b: float) -> tuple[float, float, float]:
    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.14713 * r - 0.28886 * g + 0.436 * b + 128
    v = 0.615 * r - 0.51499 * g - 0.10001 * b + 128
    return y, u, v


def classify_pixel(r: int, g: int, b: int) -> str | None:
    if r > 200 and g > 200 and b > 200:
        return None  # white sign / highlight
    if max(r, g, b) - min(r, g, b) < 25:
        return None  # grey / neutral

    if g > r * 1.22 and g > b * 1.08 and g > 55:
        return "green"
    if r > g * 1.35 and r > b * 1.35 and r > 70:
        return "red"
    if r > 70 and b > 70 and g < min(r, b) * 0.85 and r < 140:
        return "purple"
    return None


def pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    idx = int((len(s) - 1) * p)
    return s[idx]


def main() -> None:
    bin_dir = Path(__file__).resolve().parents[1] / "temp_bin_images" / "Bin"
    buckets: dict[str, list[tuple[float, float, float]]] = {
        "green": [],
        "red": [],
        "purple": [],
    }
    textures: list[float] = []

    for path in sorted(bin_dir.glob("*.jpg")):
        im = Image.open(path).convert("RGB")
        w, h = im.size
        x0, y0 = int(w * 0.08), int(h * 0.05)
        x1, y1 = int(w * 0.92), int(h * 0.95)

        for y in range(y0, y1, 4):
            row_y: list[float] = []
            for x in range(x0, x1, 4):
                r, g, b = im.getpixel((x, y))
                label = classify_pixel(r, g, b)
                if label is None:
                    continue
                yuv = rgb_to_yuv(r, g, b)
                buckets[label].append(yuv)
                row_y.append(yuv[0])
            if len(row_y) > 8:
                m = statistics.mean(row_y)
                textures.append(
                    (sum((v - m) ** 2 for v in row_y) / len(row_y)) ** 0.5
                )

    print(f"Bin-colored pixels: green={len(buckets['green'])} "
          f"red={len(buckets['red'])} purple={len(buckets['purple'])}")
    if textures:
        print(
            f"Row texture std: p10={pct(textures,0.1):.1f} "
            f"p50={pct(textures,0.5):.1f} p90={pct(textures,0.9):.1f}"
        )

    for label, pixels in buckets.items():
        if len(pixels) < 50:
            continue
        ys = [p[0] for p in pixels]
        us = [p[1] for p in pixels]
        vs = [p[2] for p in pixels]
        print(f"\n=== {label.upper()} ({len(pixels)} px) ===")
        for name, arr in [("Y", ys), ("U", us), ("V", vs)]:
            print(
                f"  {name}: p05={pct(arr,0.05):.0f} p10={pct(arr,0.10):.0f} "
                f"p50={pct(arr,0.50):.0f} p90={pct(arr,0.90):.0f} p95={pct(arr,0.95):.0f}"
            )


if __name__ == "__main__":
    main()
