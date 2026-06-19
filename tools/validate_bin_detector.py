#!/usr/bin/env python3
"""Simulate BinDetector checks on reference JPEGs (sanity check)."""
from __future__ import annotations

import math
import statistics
from pathlib import Path

from PIL import Image


COLS, ROWS = 16, 12
MIN_BBOX_COLOR = 0.18
MIN_FRAME_COVER = 0.09
MIN_HEIGHT = 0.22
MIN_TEXTURE = 15.0
MIN_MESH = 0.30
STRONG_MESH = 0.45
STRONG_TEXTURE = 19.0
MIN_DARK_CLUSTER = 2
DARK_Y = 82.0


def rgb_to_yuv(r, g, b):
    y = 0.299 * r + 0.587 * g + 0.114 * b
    u = -0.14713 * r - 0.28886 * g + 0.436 * b + 128
    v = 0.615 * r - 0.51499 * g - 0.10001 * b + 128
    return y, u, v


def match_bin(mY, mU, mV):
    uOff, vOff = mU - 128, mV - 128
    r = mY + 1.402 * vOff
    g = mY - 0.344136 * uOff - 0.714136 * vOff
    b = mY + 1.772 * uOff

    if (
        r > g * 1.38
        and r > b * 1.45
        and r > 75
        and 52 <= mY <= 145
        and 95 <= mU <= 125
        and 142 <= mV <= 235
    ):
        return "red"
    if (
        g > r * 1.24
        and g > b * 1.10
        and g > 58
        and 45 <= mY <= 145
        and 108 <= mU <= 138
        and 70 <= mV <= 115
    ):
        return "green"
    if (
        r > g * 0.88
        and b > g * 0.88
        and r < 135
        and mY < 120
        and 65 <= mY <= 115
        and 125 <= mU <= 158
        and 130 <= mV <= 162
    ):
        return "purple"
    return None


def analyze(path: Path) -> dict:
    im = Image.open(path).convert("RGB")
    fw, fh = im.size
    cell_w, cell_h = fw // COLS, fh // ROWS
    total = COLS * ROWS
    colors = [None] * total
    ys = [128.0] * total
    ystd = [0.0] * total
    mesh = [0.0] * total

    counts = {"red": 0, "green": 0, "purple": 0}

    for row in range(ROWS):
        for col in range(COLS):
            idx = row * COLS + col
            x0, y0 = col * cell_w, row * cell_h
            x1, y1 = min(x0 + cell_w, fw), min(y0 + cell_h, fh)
            samples = []
            mesh_hits = 0
            prev_row = None
            for py in range(y0, y1, 4):
                prev_col = None
                for px in range(x0, x1, 4):
                    r, g, b = im.getpixel((px, py))
                    y, u, v = rgb_to_yuv(r, g, b)
                    samples.append(y)
                    if prev_col is not None and abs(y - prev_col) > 18:
                        mesh_hits += 1
                    if prev_row is not None and abs(y - prev_row) > 18:
                        mesh_hits += 1
                    prev_col = y
                if prev_col is not None:
                    prev_row = prev_col
            if not samples:
                continue
            mY = sum(samples) / len(samples)
            ys[idx] = mY
            if len(samples) > 1:
                var = sum((s - mY) ** 2 for s in samples) / len(samples)
                ystd[idx] = math.sqrt(max(0, var))
            mesh[idx] = mesh_hits / max(1, len(samples))
            mU = mV = 128
            # average UV from samples
            us, vs = [], []
            for py in range(y0, y1, 4):
                for px in range(x0, x1, 4):
                    r, g, b = im.getpixel((px, py))
                    _, u, v = rgb_to_yuv(r, g, b)
                    us.append(u)
                    vs.append(v)
            mU, mV = sum(us) / len(us), sum(vs) / len(vs)
            label = match_bin(mY, mU, mV)
            colors[idx] = label
            if label:
                counts[label] += 1

    dom = max(counts, key=counts.get)
    dom_count = counts[dom]
    if dom_count == 0:
        return {"pass": False, "reason": "no color", "dom": dom}

    min_col = COLS
    max_col = 0
    min_row = ROWS
    max_row = 0
    for row in range(ROWS):
        for col in range(COLS):
            if colors[row * COLS + col] == dom:
                min_col = min(min_col, col)
                max_col = max(max_col, col)
                min_row = min(min_row, row)
                max_row = max(max_row, row)

    span_w = max_col - min_col + 1
    span_h = max_row - min_row + 1
    bbox = span_w * span_h
    bbox_match = sum(
        1
        for row in range(min_row, max_row + 1)
        for col in range(min_col, max_col + 1)
        if colors[row * COLS + col] == dom
    )
    stds = [
        ystd[row * COLS + col]
        for row in range(min_row, max_row + 1)
        for col in range(min_col, max_col + 1)
        if colors[row * COLS + col] == dom
    ]
    meshes = [
        mesh[row * COLS + col]
        for row in range(min_row, max_row + 1)
        for col in range(min_col, max_col + 1)
        if colors[row * COLS + col] == dom
    ]

    slot_max = min_row + int((max_row - min_row) * 0.62)
    dark = [
        (row, col)
        for row in range(min_row, slot_max + 1)
        for col in range(min_col, max_col + 1)
        if ys[row * COLS + col] < DARK_Y
    ]
    cluster = len(dark)  # loose upper bound

    checks = {
        "frame_cover": dom_count / total >= MIN_FRAME_COVER,
        "bbox_color": (bbox_match / bbox if bbox else 0) >= MIN_BBOX_COLOR,
        "texture": (sum(stds) / len(stds) if stds else 0) >= MIN_TEXTURE,
        "mesh": (sum(1 for s, m in zip(stds, meshes) if s >= 12 or m >= 0.10) / len(meshes) if meshes else 0)
        >= MIN_MESH,
        "height": (span_h / ROWS) >= MIN_HEIGHT,
        "aspect": (span_w / span_h if span_h else 99) <= 3.0,
        "dark": cluster >= MIN_DARK_CLUSTER,
    }

    return {
        "pass": all(checks.values()),
        "dom": dom,
        "checks": checks,
        "metrics": {
            "frame_cover": dom_count / total,
            "bbox_color": bbox_match / bbox if bbox else 0,
            "texture": sum(stds) / len(stds) if stds else 0,
            "dark": cluster,
        },
    }


def main() -> None:
    root = Path(__file__).resolve().parents[1] / "temp_bin_images" / "Bin"
    passed = failed = 0
    for p in sorted(root.glob("*.jpg")):
        r = analyze(p)
        if r["pass"]:
            passed += 1
        else:
            failed += 1
            bad = [k for k, v in r["checks"].items() if not v]
            print(f"FAIL {p.name}: {bad} metrics={r.get('metrics')}")
    print(f"\nPassed {passed}/{passed + failed} reference images")


if __name__ == "__main__":
    main()
