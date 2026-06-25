import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Detects bottle insertion by tracking the white slot opening on the bin.
///
/// Algorithm — 95th-percentile adaptive brightness:
///
///   Phase 1 CALIBRATING (first 20 frames):
///     Compute p95 = 95th-percentile luma in the scan zone each frame.
///     Average these → baseline. The slot (white, Y≈220) dominates the top 5%
///     of pixels even when it's only 5-10% of the scan area.
///
///   Phase 2 SLOT_VISIBLE:
///     p95 > baseline × 0.70 → slot is open, ready to detect.
///     p95 < baseline × 0.45 → bottle covering slot → BOTTLE_IN.
///
///   Phase 3 BOTTLE_IN:
///     p95 returns to > baseline × 0.65 → bottle inserted → fire onInserted().
///
/// No model, no calibration file, no colour assumptions —
/// works for any bin colour under any lighting.
class ArrowOcclusionDetector {
  ArrowOcclusionDetector({
    required this.onInserted,
    required void Function(bool ready) onReadyChanged,
    // Scan zone (normalised). Default = centre column, upper half.
    double scanLeft   = 0.28,
    double scanRight  = 0.72,
    double scanTop    = 0.08,
    double scanBottom = 0.52,
  })  : _onReadyChanged = onReadyChanged,
        _scanLeft   = scanLeft,
        _scanRight  = scanRight,
        _scanTop    = scanTop,
        _scanBottom = scanBottom;

  final VoidCallback                 onInserted;
  final void Function(bool ready)    _onReadyChanged;
  final double _scanLeft, _scanRight, _scanTop, _scanBottom;

  // ── Detection thresholds (relative to calibrated baseline) ───────────────
  static const double _coveredRatio   = 0.45; // slot "covered"  when p95 < baseline × this
  static const double _uncoveredRatio = 0.65; // slot "uncovered" when p95 > baseline × this

  // Consecutive frames to confirm each transition
  static const int _framesToCover    = 3;
  static const int _framesToUncover  = 4;

  // Calibration
  static const int    _calibFrames   = 20;
  static const double _minBaseline   = 40.0;  // sanity: baseline too low → bad aim

  // Timing guards
  static const int _minCoveredMs  = 100;  // reject flicker < 100 ms
  static const int _maxCoveredMs  = 6000; // reset if blocked > 6 s
  static const int _cooldownMs    = 1800; // minimum gap between counts

  // ── State ─────────────────────────────────────────────────────────────────
  OcclusionState _state = OcclusionState.seeking;
  int       _confirmCount = 0;
  double    _baseline     = 0.0;
  double    _calibSum     = 0.0;
  int       _calibCount   = 0;
  DateTime? _coveredAt;
  DateTime? _cooldownUntil;

  // debug throttle
  int _dbgTick = 0;

  // ── Diagnostics ───────────────────────────────────────────────────────────
  double         p95          = 0.0;  // last measured p95
  OcclusionState get state    => _state;

  // ── Main entry ────────────────────────────────────────────────────────────
  void processFrame(CameraImage image) {
    if (_cooldownUntil != null && DateTime.now().isBefore(_cooldownUntil!)) {
      return;
    }

    p95 = _measureP95(image);

    // ── Calibration phase ─────────────────────────────────────────────────
    if (_state == OcclusionState.seeking) {
      _calibSum += p95;
      _calibCount++;

      if (_calibCount >= _calibFrames) {
        _baseline = _calibSum / _calibCount;
        if (_baseline >= _minBaseline) {
          debugPrint('[ArrowOcclusion] baseline=${_baseline.toStringAsFixed(1)}');
          _changeState(OcclusionState.slotVisible);
          _onReadyChanged(true);
        } else {
          // Scene too dark / camera not aimed — restart calibration
          debugPrint('[ArrowOcclusion] baseline too low (${_baseline.toStringAsFixed(1)}), retrying');
          _calibSum = 0;
          _calibCount = 0;
        }
      }
      return;
    }

    // Relative brightness (1.0 = same as baseline, < 1.0 = darker)
    final ratio = _baseline > 0 ? p95 / _baseline : 1.0;

    // Periodic debug log
    if (++_dbgTick % 15 == 0) {
      debugPrint('[ArrowOcclusion] state=$_state '
          'p95=${p95.toStringAsFixed(1)} '
          'ratio=${ratio.toStringAsFixed(2)} '
          'baseline=${_baseline.toStringAsFixed(1)}');
    }

    switch (_state) {
      case OcclusionState.seeking:
        break; // handled above

      case OcclusionState.slotVisible:
        if (ratio < _coveredRatio) {
          _confirmCount++;
          if (_confirmCount >= _framesToCover) {
            _coveredAt = DateTime.now();
            _changeState(OcclusionState.bottleIn);
            debugPrint('[ArrowOcclusion] slot COVERED (ratio=${ratio.toStringAsFixed(2)})');
          }
        } else {
          _confirmCount = 0;
        }

      case OcclusionState.bottleIn:
        final now = DateTime.now();
        final coveredMs = _coveredAt != null
            ? now.difference(_coveredAt!).inMilliseconds
            : 0;

        // Stuck guard
        if (coveredMs > _maxCoveredMs) {
          debugPrint('[ArrowOcclusion] stuck timeout — resetting');
          _changeState(OcclusionState.slotVisible);
          return;
        }

        if (ratio > _uncoveredRatio) {
          _confirmCount++;
          if (_confirmCount >= _framesToUncover) {
            debugPrint('[ArrowOcclusion] slot UNCOVERED after ${coveredMs}ms '
                '(ratio=${ratio.toStringAsFixed(2)}) → COUNT');
            _changeState(OcclusionState.slotVisible);
            if (coveredMs >= _minCoveredMs) {
              _cooldownUntil = now.add(const Duration(milliseconds: _cooldownMs));
              onInserted();
            }
          }
        } else {
          _confirmCount = 0;
        }
    }
  }

  // ── 95th-percentile luma using a 256-bucket histogram ────────────────────
  double _measureP95(CameraImage image) {
    final int fw     = image.width;
    final int fh     = image.height;
    final yPlane     = image.planes[0].bytes;

    final int x0 = (_scanLeft   * fw).toInt();
    final int x1 = (_scanRight  * fw).toInt().clamp(0, fw);
    final int y0 = (_scanTop    * fh).toInt();
    final int y1 = (_scanBottom * fh).toInt().clamp(0, fh);

    // 256-bucket histogram (one bucket per luma value)
    final hist = List<int>.filled(256, 0);
    int total = 0;

    for (int py = y0; py < y1; py += 4) {
      for (int px = x0; px < x1; px += 4) {
        final yi = py * fw + px;
        if (yi >= yPlane.length) continue;
        hist[yPlane[yi]]++;
        total++;
      }
    }

    if (total == 0) return 0;

    // Walk from bright to dark; return the luma value where cumulative
    // count first reaches 5% of total (i.e. the 95th percentile).
    final target = (total * 0.05).round().clamp(1, total);
    int cum = 0;
    for (int i = 255; i >= 0; i--) {
      cum += hist[i];
      if (cum >= target) return i.toDouble();
    }
    return 0;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  void _changeState(OcclusionState next) {
    _state = next;
    _confirmCount = 0;
  }

  void reset() {
    _state        = OcclusionState.seeking;
    _confirmCount = 0;
    _calibSum     = 0;
    _calibCount   = 0;
    _baseline     = 0;
    _coveredAt    = null;
    _cooldownUntil = null;
    p95           = 0;
    _dbgTick      = 0;
  }
}

enum OcclusionState { seeking, slotVisible, bottleIn }
