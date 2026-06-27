import 'dart:io';
import 'package:camera/camera.dart';
import '../../services/sound_spike_detector.dart';

enum _PassState {
  idle,
  entering,
  inside,
  exiting,
}

/// Metrics for a single completed detection attempt — sent for EVERY
/// attempt (whether it ended up counted or rejected), so the app can
/// keep collecting real calibration data forever, not just at the
/// 35-video snapshot used to set the current defaults.
class InsertionAttemptResult {
  const InsertionAttemptResult({
    required this.counted,
    required this.rejectedReason,
    required this.peakChangeFraction,
    required this.peakDownwardScore,
    required this.avgCornerMotion,
    required this.durationMs,
  });

  final bool counted;

  /// null if counted; otherwise 'cameraShake' or 'lowConfidence'
  final String? rejectedReason;
  final double peakChangeFraction;
  final double peakDownwardScore;
  final double avgCornerMotion;
  final int durationMs;
}

class _LumaSample {
  const _LumaSample({
    required this.pixels,
    required this.rows,
    required this.cols,
  });

  final List<int> pixels;
  final int rows;
  final int cols;
}

/// Motion-based detector for the bin opening slot.
///
/// 5-filter pipeline adapted for this app:
/// 1) zone filter, 2) motion size, 3) downward direction,
/// 4) entry->inside->exit state machine, 5) cooldown.
class SlotMotionDetectionImpl {
  SlotMotionDetectionImpl({
    required void Function() onMotionDetected,
    required void Function(bool isReady) onReadyChanged,
    required double regionLeft,
    required double regionTop,
    required double regionWidth,
    required double regionHeight,
    void Function(InsertionAttemptResult result)? onAttemptComplete,
    // Optional threshold overrides — pass these from Firebase Remote Config
    // so the detector can be recalibrated from real collected data WITHOUT
    // an app store update. Falls back to the 35-video-calibrated defaults.
    double? minChangeFractionOverride,
    double? minDownwardScoreOverride,
    double? maxCornerMotionAvgOverride,
    // Optional sound-spike detector. CAMERA DETECTION IS COMPULSORY and
    // works fully on its own — sound is only ever a helper. If a spike
    // lands near a borderline camera signal, the camera bar is relaxed
    // slightly for that one attempt. If sound disagrees, says nothing, or
    // isn't running at all (mic permission denied/unsupported), the
    // camera decides entirely by itself at the normal, stricter bar.
    SoundSpikeDetector? soundDetector,
  })  : _soundDetector = soundDetector,
        _onMotionDetected = onMotionDetected,
        _onReadyChanged = onReadyChanged,
        _regionLeft = regionLeft,
        _regionTop = regionTop,
        _regionWidth = regionWidth,
        _regionHeight = regionHeight,
        _onAttemptComplete = onAttemptComplete,
        _minChangeFraction =
            minChangeFractionOverride ?? _defaultMinChangeFraction,
        _minDownwardScore =
            minDownwardScoreOverride ?? _defaultMinDownwardScore;

  final SoundSpikeDetector? _soundDetector;
  final void Function() _onMotionDetected;
  final void Function(bool isReady) _onReadyChanged;
  final void Function(InsertionAttemptResult result)? _onAttemptComplete;
  final double _regionLeft;
  final double _regionTop;
  final double _regionWidth;
  final double _regionHeight;

  // Instance thresholds — overridable per-instance via Remote Config,
  // default to the 35-video-calibrated values if no override is given.
  final double _minChangeFraction;
  final double _minDownwardScore;

  _LumaSample? _previousSample;
  bool _disposed = false;
  bool _readyNotified = false;

  static const int _warmupFrames = 8;
  static const int _sampleStep = 2;

  // Filter 2: min changed fraction in zone
  static const double _defaultMinChangeFraction =
      0.04; // lowered: small/fast insertions and mesh slots change fewer pixels
  // Filter 3: downward dominance score threshold
  static const double _defaultMinDownwardScore =
      0.10; // lowered: bottles enter at many angles (horizontal, diagonal)
  // Filter 5: cooldown after each count
  static const int _cooldownMs = 2000; // faster cooldown for open-top bins
  // Pixel diff threshold for per-pixel motion map
  static const int _pixelDiffThreshold =
      12; // lowered: wire mesh and plastic slots reduce per-pixel diff
  static const int _bands = 20;

  // ── Anti camera-shake guard ────────────────────────────────────────────────
  // Calibrated by comparing 35 real insertion videos against a recorded
  // false-trigger clip (hand+bottle reaching toward the bin then withdrawing,
  // recorded while the phone itself was moved/shaken).
  //
  // Simple motion-amount checks CANNOT tell these apart — the false-trigger
  // clip had MORE peak motion (0.527) than every real insertion, and its
  // down-score (0.454) sat in the middle of the real range too.
  //
  // The one signal that cleanly separated them: background/corner motion.
  // Real insertions only disturb the bottle/hand region — the frame corners
  // (walls, bin edges) stay still. When the WHOLE frame moves together
  // (corners included), that means the camera itself moved, not the bottle.
  //
  //   35 real insertions — avg corner motion: 0.088 to 0.295 (max 0.295)
  //   False-trigger clip  — avg corner motion: 0.363   ← clearly higher
  //
  static const double _cornerFrac =
      0.15; // each corner patch = 15% of width/height
  static const int _cornerPixelDiffThreshold = 18;

  int _frameCount = 0;
  _PassState _state = _PassState.idle;
  DateTime? _lastCount;
  final List<double> _rowHistory = List<double>.filled(_bands, 0.0);

  double _changedFraction = 0;
  double _downwardScore = 0;

  // Anti-shake tracking — accumulated only during an active entering/inside/
  // exiting attempt, reset whenever a new attempt starts.
  _LumaSample? _previousCornerSample;
  double _cornerMotionSum = 0;
  int _cornerMotionCount = 0;

  // Peak metrics for the CURRENT attempt — reported via onAttemptComplete
  // for every attempt (counted or not) so real usage keeps improving
  // calibration over time, not just the one-time 35-video snapshot.
  double _peakChangeFraction = 0;
  double _peakDownwardScore = 0;
  DateTime? _attemptStart;

  void processImage(CameraImage image) {
    if (_disposed) return;

    try {
      _frameCount++;

      final sample = _extractLuminance(image);
      if (sample == null || sample.pixels.isEmpty) return;

      // Sample the 4 frame corners too — used to detect camera shake
      // (see _maxCornerMotionAvg comment above for why this is needed).
      final cornerSample = _extractCornerLuminance(image);

      if (_frameCount <= _warmupFrames) {
        _previousSample = sample;
        _previousCornerSample = cornerSample;
        return;
      }

      // Once warmed up, the detector is ALWAYS ready — there is no separate
      // "calibration" phase that needs a calm background. For handheld use
      // (user holding the phone, pointing at the bin) the frame never goes
      // fully still, so a calm-frame requirement left it stuck forever.
      _notifyReady(true);

      if (_previousSample == null ||
          _previousSample!.pixels.length != sample.pixels.length ||
          _previousSample!.rows != sample.rows ||
          _previousSample!.cols != sample.cols) {
        _previousSample = sample;
        _state = _PassState.idle;
        _resetRows();
        _notifyReady(false);
        return;
      }

      final previous = _previousSample!;
      final zoneLen = sample.pixels.length;
      if (zoneLen == 0) {
        _previousSample = sample;
        return;
      }

      if (_inCooldown()) {
        _notifyReady(false);
        _previousSample = sample;
        return;
      }

      final bandMotion = List<double>.filled(_bands, 0.0);
      var totalChanged = 0;

      final zoneW = sample.cols;
      final zoneH = sample.rows;

      for (var i = 0; i < zoneLen; i++) {
        final diff = (sample.pixels[i] - previous.pixels[i]).abs();
        if (diff > _pixelDiffThreshold) {
          totalChanged++;
          final row = i ~/ zoneW;
          final band = ((row / zoneH) * _bands).clamp(0, _bands - 1).toInt();
          bandMotion[band] += 1.0;
        }
      }

      // Filter 2: motion must be significant enough in slot zone.
      _changedFraction = totalChanged / zoneLen;
      if (_state != _PassState.idle && _changedFraction > _peakChangeFraction) {
        _peakChangeFraction = _changedFraction;
      }

      // ── Corner motion (anti-shake) — accumulate only while an attempt
      // is in progress (state != idle). Reset happens at idle→entering below.
      if (_state != _PassState.idle &&
          cornerSample != null &&
          _previousCornerSample != null &&
          cornerSample.pixels.length == _previousCornerSample!.pixels.length) {
        var cornerChanged = 0;
        final cPixels = cornerSample.pixels;
        final pPixels = _previousCornerSample!.pixels;
        for (var i = 0; i < cPixels.length; i++) {
          if ((cPixels[i] - pPixels[i]).abs() > _cornerPixelDiffThreshold) {
            cornerChanged++;
          }
        }
        final cornerFraction =
            cPixels.isEmpty ? 0.0 : cornerChanged / cPixels.length;
        _cornerMotionSum += cornerFraction;
        _cornerMotionCount++;
      }
      _previousCornerSample = cornerSample;

      if (_changedFraction < _minChangeFraction) {
        final shouldCount =
            _state == _PassState.inside || _state == _PassState.exiting;
        _state = _PassState.idle;
        _resetRows();
        _notifyReady(true);

        if (shouldCount) {
          _lastCount = DateTime.now();
          _notifyReady(false);

          // Anti-shake gate: if the background corners moved as much as the
          // bin region did, the whole camera was shaken/moved — not a real
          // bottle insertion. Suppress the count but keep the cooldown,
          // so a single mis-trigger doesn't immediately retry.
          final avgCornerMotion = _cornerMotionCount > 0
              ? _cornerMotionSum / _cornerMotionCount
              : 0.0;

          // Adaptive anti-shake: compare slot-zone motion to background motion
          // as a RATIO, not an absolute threshold. Works for handheld use —
          // the whole frame may be moving, but a real insertion still makes
          // the SLOT ZONE move noticeably more than the background corners.
          // Reject only if the zone motion barely exceeded the background
          // (i.e. the "motion" was just whole-camera movement, no insertion).
          // ── Camera is the COMPULSORY signal ─────────────────────────────
          // The zone-vs-background motion ratio is always the deciding
          // check — this works fully on its own with no sound at all.
          final zoneVsBackground = avgCornerMotion > 0.001
              ? _peakChangeFraction / avgCornerMotion
              : 99.0;

          // ── Sound is an OPTIONAL helper, never a requirement ────────────
          // If a spike landed near this moment, it's corroborating evidence
          // for a borderline camera signal — so the camera bar is relaxed
          // a little (2.2 → 1.3). If sound disagrees, says nothing, or the
          // detector isn't running at all (denied permission/unsupported),
          // the camera still decides entirely on its own at the stricter
          // bar. Sound can only make a count MORE likely, never block one.
          final soundConfirmed = _soundDetector?.hadRecentSpike(
                window: const Duration(milliseconds: 900),
              ) ??
              false;
          // 1.5 allows normal hand steadiness during insertion;
          // sound spike is strong corroborating evidence, so drop to 1.0.
          final requiredRatio = soundConfirmed ? 1.0 : 1.5;

          final counted = zoneVsBackground >= requiredRatio;
          final String? rejectedReason = counted
              ? null
              : (soundConfirmed ? 'cameraShake' : 'cameraShakeNoSound');

          _cornerMotionSum = 0;
          _cornerMotionCount = 0;

          // Report this attempt for continuous data collection — sent for
          // BOTH outcomes so the calibration can keep improving from real
          // usage instead of staying frozen at the 35-video snapshot.
          final durationMs = _attemptStart != null
              ? DateTime.now().difference(_attemptStart!).inMilliseconds
              : 0;
          _onAttemptComplete?.call(InsertionAttemptResult(
            counted: counted,
            rejectedReason: rejectedReason,
            peakChangeFraction: _peakChangeFraction,
            peakDownwardScore: _peakDownwardScore,
            avgCornerMotion: avgCornerMotion,
            durationMs: durationMs,
          ));

          if (counted) {
            _onMotionDetected();
          }

          _previousSample = sample;
          return;
        }

        _previousSample = sample;
        return;
      }

      _notifyReady(false);

      // Smooth band motion and compute direction bias.
      final bandMax = bandMotion.reduce((a, b) => a > b ? a : b);
      if (bandMax > 0) {
        for (var b = 0; b < _bands; b++) {
          _rowHistory[b] =
              _rowHistory[b] * 0.6 + (bandMotion[b] / bandMax) * 0.4;
        }
      }

      var upperSum = 0.0;
      var lowerSum = 0.0;
      for (var b = 0; b < _bands ~/ 2; b++) {
        upperSum += _rowHistory[b];
      }
      for (var b = _bands ~/ 2; b < _bands; b++) {
        lowerSum += _rowHistory[b];
      }

      final total = upperSum + lowerSum;
      _downwardScore = total > 0 ? lowerSum / total : 0;
      if (_state != _PassState.idle && _downwardScore > _peakDownwardScore) {
        _peakDownwardScore = _downwardScore;
      }

      // Filter 3: ignore sideways/upward jitter.
      if (_downwardScore < _minDownwardScore) {
        _previousSample = sample;
        return;
      }

      // Filter 4: entry -> inside -> exiting progression.
      double weightedBand = 0;
      double weightSum = 0;
      for (var b = 0; b < _bands; b++) {
        weightedBand += b * bandMotion[b];
        weightSum += bandMotion[b];
      }

      final centroid = weightSum > 0 ? weightedBand / weightSum : 0;
      final relPos = centroid / _bands;

      switch (_state) {
        case _PassState.idle:
          if (relPos < 0.80 && _changedFraction > _minChangeFraction * 0.8) {
            // wider centroid range: bottle can enter from anywhere in the zone
            _state = _PassState.entering;
            // Fresh attempt — clear any stale tracking from a prior attempt.
            _cornerMotionSum = 0;
            _cornerMotionCount = 0;
            _peakChangeFraction = _changedFraction;
            _peakDownwardScore = 0;
            _attemptStart = DateTime.now();
          }
          break;
        case _PassState.entering:
          if (relPos >= 0.30) {
            _state = _PassState.inside;
          }
          break;
        case _PassState.inside:
          if (relPos > 0.60) {
            _state = _PassState.exiting;
          }
          break;
        case _PassState.exiting:
          // Count on the next low-motion frame.
          break;
      }

      _previousSample = sample;
    } catch (_) {
      // Ignore platform-specific image processing failures and keep streaming.
    }
  }

  bool _inCooldown() {
    final lastCount = _lastCount;
    if (lastCount == null) return false;
    return DateTime.now().difference(lastCount).inMilliseconds < _cooldownMs;
  }

  void _resetRows() {
    for (var i = 0; i < _rowHistory.length; i++) {
      _rowHistory[i] = 0;
    }
  }

  _LumaSample? _extractLuminance(CameraImage image) {
    if (image.planes.isEmpty) return null;

    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;

    final safeLeft = _regionLeft.clamp(0.0, 0.95);
    final safeTop = _regionTop.clamp(0.0, 0.95);
    final safeWidth = _regionWidth.clamp(0.05, 1.0 - safeLeft);
    final safeHeight = _regionHeight.clamp(0.05, 1.0 - safeTop);

    final left = (width * safeLeft).round();
    final top = (height * safeTop).round();
    final regionWidth = (width * safeWidth).round().clamp(1, width - left);
    final regionHeight = (height * safeHeight).round().clamp(1, height - top);

    if (Platform.isIOS) {
      return _extractBGRA(
          image, left, top, regionWidth, regionHeight, width, height);
    }

    return _extractYUV(
        image, left, top, regionWidth, regionHeight, width, height);
  }

  _LumaSample? _extractYUV(
    CameraImage image,
    int left,
    int top,
    int regionWidth,
    int regionHeight,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];
    var rows = 0;
    var cols = 0;

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      var rowCols = 0;
      for (var x = left;
          x < left + regionWidth && x < width;
          x += _sampleStep) {
        final offset = y * bytesPerRow + x;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
          rowCols++;
        }
      }
      if (rowCols > 0) {
        rows++;
        cols = rowCols;
      }
    }

    if (out.isEmpty || rows == 0 || cols == 0) return null;
    return _LumaSample(pixels: out, rows: rows, cols: cols);
  }

  _LumaSample? _extractBGRA(
    CameraImage image,
    int left,
    int top,
    int regionWidth,
    int regionHeight,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];
    var rows = 0;
    var cols = 0;

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      var rowCols = 0;
      for (var x = left;
          x < left + regionWidth && x < width;
          x += _sampleStep) {
        final offset = y * bytesPerRow + x * 4 + 1;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
          rowCols++;
        }
      }
      if (rowCols > 0) {
        rows++;
        cols = rowCols;
      }
    }

    if (out.isEmpty || rows == 0 || cols == 0) return null;
    return _LumaSample(pixels: out, rows: rows, cols: cols);
  }

  /// Samples small patches from the 4 corners of the FULL frame
  /// (outside the configured bin/slot region) to detect camera shake.
  /// If the background corners move as much as the bin region, the
  /// whole camera moved — not just the bottle/hand inside it.
  _LumaSample? _extractCornerLuminance(CameraImage image) {
    if (image.planes.isEmpty) return null;

    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;

    final cw = (width * _cornerFrac).round().clamp(2, width);
    final ch = (height * _cornerFrac).round().clamp(2, height);

    if (Platform.isIOS) {
      return _extractCornersBGRA(image, cw, ch, width, height);
    }
    return _extractCornersYUV(image, cw, ch, width, height);
  }

  _LumaSample? _extractCornersYUV(
    CameraImage image,
    int cw,
    int ch,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];

    // 4 corner rectangles: top-left, top-right, bottom-left, bottom-right
    final corners = <List<int>>[
      [0, 0],
      [width - cw, 0],
      [0, height - ch],
      [width - cw, height - ch],
    ];

    for (final corner in corners) {
      final left = corner[0];
      final top = corner[1];
      for (var y = top; y < top + ch && y < height; y += _sampleStep) {
        for (var x = left; x < left + cw && x < width; x += _sampleStep) {
          final offset = y * bytesPerRow + x;
          if (offset >= 0 && offset < bytes.length) {
            out.add(bytes[offset] & 0xff);
          }
        }
      }
    }

    if (out.isEmpty) return null;
    return _LumaSample(pixels: out, rows: 1, cols: out.length);
  }

  _LumaSample? _extractCornersBGRA(
    CameraImage image,
    int cw,
    int ch,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];

    final corners = <List<int>>[
      [0, 0],
      [width - cw, 0],
      [0, height - ch],
      [width - cw, height - ch],
    ];

    for (final corner in corners) {
      final left = corner[0];
      final top = corner[1];
      for (var y = top; y < top + ch && y < height; y += _sampleStep) {
        for (var x = left; x < left + cw && x < width; x += _sampleStep) {
          final offset = y * bytesPerRow + x * 4 + 1;
          if (offset >= 0 && offset < bytes.length) {
            out.add(bytes[offset] & 0xff);
          }
        }
      }
    }

    if (out.isEmpty) return null;
    return _LumaSample(pixels: out, rows: 1, cols: out.length);
  }

  void _notifyReady(bool ready) {
    if (_readyNotified == ready) return;
    _readyNotified = ready;
    _onReadyChanged(ready);
  }

  void dispose() {
    _disposed = true;
    _previousSample = null;
  }
}
