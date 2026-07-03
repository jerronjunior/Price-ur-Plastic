#!/usr/bin/env python3
"""
train_insertion_action_model.py
────────────────────────────────
Trains a lightweight logistic-regression model for bottle-insertion action
classification from short video clips.

The feature definitions are designed to match the Dart implementation in:
lib/screens/scan/slot_motion_detection_impl.dart

Usage:
  python tools/train_insertion_action_model.py --positives videos/ --negatives negs/

Folder layout:
  positives/  ← short clips (1-3s) each containing ONE real insertion
  negatives/  ← clips with NO insertion (hand waving, camera shake, walking by)

Output:
  Prints Dart constants that can be pasted into LearnedInsertionModel.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

try:
    import cv2
except ImportError as exc:  # pragma: no cover - runtime environment guard
    print("OpenCV is required. Install it with: pip install opencv-python numpy")
    raise SystemExit(1) from exc

WIN = 10
VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".mkv"}


def frame_metrics(video_path: Path, bshift: int = 0) -> np.ndarray:
    """Compute per-frame motion metrics for a video clip."""
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print(f"Warning: could not open video {video_path}")
        return np.empty((0, 3), dtype=float)

    prev = None
    out: list[tuple[float, float, float]] = []

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame is None:
            continue

        h, w = frame.shape[:2]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.int16)
        if bshift:
            gray = np.clip(gray + bshift, 0, 255)

        if prev is not None and prev.shape == gray.shape:
            diff = np.abs(gray - prev)
            zone_roi = diff[int(h * 0.18):int(h * 0.52), int(w * 0.30):int(w * 0.70)]
            zone = float(np.mean(zone_roi > 18))
            mid = zone_roi.shape[0] // 2
            top = zone_roi[:mid]
            bottom = zone_roi[mid:]
            down = bottom.mean() / (top.mean() + bottom.mean() + 1e-3)

            cw, ch = int(w * 0.15), int(h * 0.15)
            corners = [
                diff[0:ch, 0:cw],
                diff[0:ch, w - cw:w],
                diff[h - ch:h, 0:cw],
                diff[h - ch:h, w - cw:w],
            ]
            corner = float(np.mean([np.mean(c > 18) for c in corners]))
            out.append((zone, down, corner))

        prev = gray

    cap.release()
    return np.array(out, dtype=float)


def window_features(m: np.ndarray) -> list[float]:
    """Summarize a sliding window of motion metrics into 8 logistic features."""
    zone, down, corner = m[:, 0], m[:, 1], m[:, 2]
    ratio = zone / (corner + 1e-3)
    half = WIN // 2
    return [
        float(zone.mean()),
        float(zone.max()),
        float(down.mean()),
        float(down.max()),
        float(corner.mean()),
        min(float(ratio.mean()), 30.0),
        float(zone[half:].mean() - zone[:half].mean()),
        float(zone.std()),
    ]


def collect_video_paths(folder: Path) -> list[Path]:
    if not folder.exists():
        print(f"Warning: folder does not exist: {folder}")
        return []
    return sorted(
        p for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positives", required=True, help="Folder containing positive insertion clips")
    parser.add_argument("--negatives", required=True, help="Folder containing negative clips")
    args = parser.parse_args()

    positives = Path(args.positives)
    negatives = Path(args.negatives)

    X, y, wts = [], [], []

    for video_path in collect_video_paths(positives):
        metrics = frame_metrics(video_path)
        if len(metrics) < WIN:
            continue
        zsum = np.convolve(metrics[:, 0], np.ones(WIN), "valid")
        if len(zsum) == 0:
            continue
        peak = int(np.argmax(zsum))

        for start in range(0, len(metrics) - WIN + 1, 2):
            feat = window_features(metrics[start:start + WIN])
            if abs(start - peak) <= WIN:
                X.append(feat)
                y.append(1)
                wts.append(1.0)
            elif zsum[min(start, len(zsum) - 1)] < 0.35 * zsum[peak]:
                X.append(feat)
                y.append(0)
                wts.append(1.0)

    for video_path in collect_video_paths(negatives):
        for shift in [0, -20, -10, 10, 20]:
            metrics = frame_metrics(video_path, bshift=shift)
            if len(metrics) < WIN:
                continue
            for start in range(0, len(metrics) - WIN + 1, 1):
                X.append(window_features(metrics[start:start + WIN]))
                y.append(0)
                wts.append(3.0)

    if not X:
        print("No usable training windows were collected. Check the input folders and video formats.")
        sys.exit(1)

    X = np.array(X, dtype=float)
    y = np.array(y, dtype=float)
    wts = np.array(wts, dtype=float)

    print(f"Dataset: {len(y)} windows — {int(y.sum())} pos, {int((y == 0).sum())} neg")

    mu, sd = X.mean(axis=0), X.std(axis=0) + 1e-6
    Xs = (X - mu) / sd
    w = np.zeros(X.shape[1], dtype=float)
    b = 0.0

    for _ in range(4000):
        p = 1.0 / (1.0 + np.exp(-(Xs @ w + b)))
        g = (p - y) * wts
        w -= 0.4 * (Xs.T @ g) / wts.sum() + 0.0005 * w
        b -= 0.4 * g.mean()

    p_all = 1.0 / (1.0 + np.exp(-(Xs @ w + b)))
    for threshold in [0.5, 0.6]:
        recall = (p_all[y == 1] > threshold).mean()
        hard_neg_fp = (p_all[(y == 0) & (wts == 3.0)] > threshold).mean()
        print(f"threshold {threshold}: insertion recall {recall * 100:.1f}%  hard-negative FP {hard_neg_fp * 100:.1f}%")

    def fmt(values: np.ndarray) -> str:
        return ", ".join(f"{x:.4f}" for x in values)

    print("\n─── Paste into LearnedInsertionModel (Dart) ───")
    print(f"  static const List<double> _w = [\n    {fmt(w)},\n  ];")
    print(f"  static const double _b = {b:.4f};")
    print(f"  static const List<double> _mu = [\n    {fmt(mu)},\n  ];")
    print(f"  static const List<double> _sd = [\n    {fmt(sd)},\n  ];")


if __name__ == "__main__":
    main()
