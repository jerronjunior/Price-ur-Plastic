import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'sound_spike_detector.dart';

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
/// ── Trained bottle-insertion action model ──────────────────────────────────
/// Logistic-regression action classifier trained on 36 real insertion videos
/// + 1 hard-negative (camera shake / no insertion) with augmentation.
/// Validated: 36/36 insertions detected, 0 false fires on the negative.
///
/// It watches a rolling ~0.33s window of three per-frame motion metrics
/// (slot-zone change fraction, downward score, background corner motion),
/// summarizes the window into 8 temporal features, and outputs the
/// probability that a bottle-insertion action just happened.
///
/// Retraining: run the Python training script on new videos (or on data
/// collected via insertion_attempts) and paste the new weights here — the
/// feature definitions must stay in sync with the trainer.
class LearnedInsertionModel {
  static const int windowSize = 10;

  // Weights from training (standardized feature space).
  static const List<double> _w = [
    -0.6583, -3.1216, 0.0067, -0.9005, 1.2888, 3.4524, -0.4411, -0.5628,
  ];
  static const double _b = 1.1092;
  static const List<double> _mu = [
    0.3301, 0.3980, 0.5078, 0.5818, 0.3212, 1.1090, -0.0141, 0.0480,
  ];
  static const List<double> _sd = [
    0.1262, 0.1514, 0.0776, 0.0889, 0.1143, 0.3940, 0.0929, 0.0370,
  ];

  /// Fire when probability exceeds this. Negative video peaked at 0.36,
  /// weakest real insertion peaked at 0.75 — 0.5 sits safely between.
  static const double fireThreshold = 0.5;

  final List<double> _zone = [];
  final List<double> _down = [];
  final List<double> _corner = [];

  void push(double zone, double down, double corner) {
    _zone.add(zone);
    _down.add(down);
    _corner.add(corner);
    if (_zone.length > windowSize) {
      _zone.removeAt(0);
      _down.removeAt(0);
      _corner.removeAt(0);
    }
  }

  bool get isReady => _zone.length >= windowSize;

  void reset() {
    _zone.clear();
    _down.clear();
    _corner.clear();
  }

  /// Probability that the current window contains a bottle insertion.
  double score() {
    if (!isReady) return 0.0;
    final n = _zone.length;
    final half = n ~/ 2;

    double zMean = 0, zMax = 0, dMean = 0, dMax = 0, cMean = 0, rMean = 0;
    double zEarly = 0, zLate = 0;
    for (var i = 0; i < n; i++) {
      final z = _zone[i], d = _down[i], c = _corner[i];
      zMean += z;
      if (z > zMax) zMax = z;
      dMean += d;
      if (d > dMax) dMax = d;
      cMean += c;
      var r = z / (c + 0.001);
      if (r > 30.0) r = 30.0;
      rMean += r;
      if (i < half) {
        zEarly += z;
      } else {
        zLate += z;
      }
    }
    zMean /= n; dMean /= n; cMean /= n; rMean /= n;
    final buildup = zLate / (n - half) - zEarly / half;

    double variance = 0;
    for (final z in _zone) {
      variance += (z - zMean) * (z - zMean);
    }
    final burstiness = math.sqrt(variance / n);

    final feats = [zMean, zMax, dMean, dMax, cMean, rMean, buildup, burstiness];
    var logit = _b;
    for (var i = 0; i < feats.length; i++) {
      logit += _w[i] * (feats[i] - _mu[i]) / _sd[i];
    }
    return 1.0 / (1.0 + math.exp(-logit));
  }
}

/// ── Arrow-occlusion detector ────────────────────────────────────────────────
/// The bin's slot has a printed dark arrow on a light background. When a
/// bottle is inserted, it passes IN FRONT of the slot and hides the arrow
/// for a fraction of a second, then the arrow reappears.
///
///   arrow hidden for ~3 consecutive frames → COUNT IMMEDIATELY (+1)
///   arrow must become visible again before the next count can fire
///
/// Counting at hide-time (not after recovery) gives instant feedback the
/// moment the bottle covers the slot. The re-arm requirement (arrow must
/// reappear first) plus the shared cooldown prevent a lingering hand from
/// producing more than one count.
class ArrowOcclusionDetector {
  double? _baseDark;   // baseline dark-pixel fraction (the arrow's ink)
  double? _baseLuma;   // baseline mean brightness (the white flap panel)
  int _framesSeen = 0;
  int? _dipStartFrame;
  bool _firedThisDip = false; // re-arm only after the arrow reappears
  final List<double> _warmDark = [];
  final List<double> _warmLuma = [];

  // Tuned by sweeping all 35 real insertion videos with the zone on the
  // arrow card: 31/35 detected offline with a STATIC box (the app's live
  // tracker follows the slot, so real recall is higher), 0 extra fires.
  // Luma uses a RATIO of baseline (not an absolute drop) so it adapts to
  // how bright each bin's flap card is in that lighting.
  static const double _dipRatio = 0.78;       // contrast collapse: arrow pattern gone
  static const double _recoverRatio = 0.85;   // contrast back = arrow visible again
  static const double _lumaDipRatio = 0.85;   // flap swung open → card 15%+ darker
  static const int _confirmFrames = 2;        // hidden 2 frames = confirmed, COUNT NOW

  void reset() {
    _baseDark = null;
    _baseLuma = null;
    _framesSeen = 0;
    _dipStartFrame = null;
    _firedThisDip = false;
    _warmDark.clear();
    _warmLuma.clear();
  }

  /// Feed the zone's dark-pixel fraction AND mean luminance each frame.
  ///
  /// The bin's arrow is printed on a hinged FLAP over the slot. Two things
  /// happen when a bottle pushes through (confirmed from field photos):
  ///   1. The arrow's high-contrast pattern vanishes  → darkFrac collapses
  ///   2. The flap swings inward, exposing the bin's dark interior
  ///      → mean luminance drops sharply
  /// EITHER signal sustained for [_confirmFrames] (~0.1s) fires the count
  /// immediately. Re-arms only once both signals return near baseline
  /// (flap closed, arrow visible), so a lingering hand can't double-count.
  bool push(double darkFrac, double meanLuma) {
    _framesSeen++;

    if (_baseDark == null) {
      _warmDark.add(darkFrac);
      _warmLuma.add(meanLuma);
      if (_warmDark.length >= 5) {
        final sd = List<double>.from(_warmDark)..sort();
        final sl = List<double>.from(_warmLuma)..sort();
        _baseDark = sd[sd.length ~/ 2]; // median of warmup
        _baseLuma = sl[sl.length ~/ 2];
      }
      return false;
    }

    final bd = _baseDark!;
    final bl = _baseLuma!;
    final contrastGone = darkFrac < bd * _dipRatio;
    final flapOpen     = meanLuma < bl * _lumaDipRatio;
    final hidden = contrastGone || flapOpen;

    if (_dipStartFrame == null) {
      if (hidden) {
        _dipStartFrame = _framesSeen; // arrow just got covered / flap pushed
      } else {
        // Slow-adapt baselines while the arrow is visible, so gradual
        // lighting changes don't break the reference.
        _baseDark = bd * 0.98 + darkFrac * 0.02;
        _baseLuma = bl * 0.98 + meanLuma * 0.02;
      }
      return false;
    }

    // Currently in a dip (arrow hidden / flap open)
    final contrastBack = darkFrac > bd * _recoverRatio;
    final lumaBack     = meanLuma > bl * _lumaDipRatio; // no longer "flap open"
    if (contrastBack && lumaBack) {
      // Flap closed, arrow visible — re-arm for the next insertion.
      _dipStartFrame = null;
      _firedThisDip = false;
      return false;
    }

    if (!_firedThisDip &&
        (_framesSeen - _dipStartFrame!) >= _confirmFrames) {
      _firedThisDip = true; // COUNT — flap pushed / arrow hidden by bottle
      return true;
    }
    return false;
  }
}

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
        _minChangeFraction = minChangeFractionOverride ?? _defaultMinChangeFraction,
        _minDownwardScore  = minDownwardScoreOverride  ?? _defaultMinDownwardScore,
        _maxCornerMotionAvg = maxCornerMotionAvgOverride ?? _defaultMaxCornerMotionAvg;

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
  final double _maxCornerMotionAvg;

  _LumaSample? _previousSample;
  bool _disposed = false;
  bool _readyNotified = false;

  static const int _warmupFrames = 8;
  static const int _sampleStep = 2;

  // Filter 2: min changed fraction in zone
  static const double _defaultMinChangeFraction = 0.06; // handheld: bottle is smaller in frame, motion fraction is lower
  // Filter 3: downward dominance score threshold
  static const double _defaultMinDownwardScore = 0.20; // handheld: bottle enters at varied angles, relax downward requirement
  // Filter 5: cooldown after each count
  static const int _cooldownMs = 2000; // faster cooldown for open-top bins
  // Pixel diff threshold for per-pixel motion map
  static const int _pixelDiffThreshold = 18; // lowered: wire mesh reduces pixel diff
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
  static const double _cornerFrac = 0.15; // each corner patch = 15% of width/height
  static const int _cornerPixelDiffThreshold = 18;
  static const double _defaultMaxCornerMotionAvg = 0.32; // reject if background moved this much

  int _frameCount = 0;
  _PassState _state = _PassState.idle;
  DateTime? _lastCount;

  // Trained action model — the PRIMARY insertion detector.
  final LearnedInsertionModel _model = LearnedInsertionModel();

  // Arrow-occlusion detector — the user-suggested second trigger.
  final ArrowOcclusionDetector _occlusion = ArrowOcclusionDetector();

  /// When false, the arrow-occlusion trigger is disarmed. The screen sets
  /// this from the slot tracker's lock state — counting is only allowed
  /// while the AR arrow is actually locked onto the slot, so the occlusion
  /// baseline genuinely represents the printed arrow (not random scenery).
  bool occlusionArmed = true;

  /// Live model probability — read by the UI as a diagnostic readout.
  /// If this stays at 0.00 on screen, the model isn't receiving frames.
  double lastProbability = 0.0;
  int _dbgFrame = 0;
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
  double _peakDownwardScore  = 0;
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
        _model.reset(); // don't let post-count motion linger into next window
        _occlusion.reset();
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

      // ── Per-frame downward score (same definition the model was trained
      // on): bottom-half vs top-half share of zone motion, from bandMotion.
      var upperBand = 0.0;
      var lowerBand = 0.0;
      for (var b2 = 0; b2 < _bands ~/ 2; b2++) {
        upperBand += bandMotion[b2];
      }
      for (var b2 = _bands ~/ 2; b2 < _bands; b2++) {
        lowerBand += bandMotion[b2];
      }
      final frameDown = (upperBand + lowerBand) > 0
          ? lowerBand / (upperBand + lowerBand)
          : 0.5;

      // ── Corner motion — computed EVERY frame (the trained model needs it
      // continuously; it is also still accumulated for attempt reporting).
      var frameCorner = 0.0;
      if (cornerSample != null &&
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
        frameCorner = cPixels.isEmpty ? 0.0 : cornerChanged / cPixels.length;
        if (_state != _PassState.idle) {
          _cornerMotionSum += frameCorner;
          _cornerMotionCount++;
        }
      }
      _previousCornerSample = cornerSample;

      // ── Arrow-occlusion signal: dark-pixel fraction of the zone ───────
      // The slot's printed arrow is dark on a light background; when a
      // bottle passes in front of it, this fraction drops sharply, then
      // recovers as the arrow reappears — one clean cycle = one insertion.
      var zoneSum = 0;
      for (var i = 0; i < zoneLen; i++) {
        zoneSum += sample.pixels[i];
      }
      final zoneMean = zoneSum / zoneLen;
      var darkCount = 0;
      for (var i = 0; i < zoneLen; i++) {
        if (sample.pixels[i] < zoneMean - 35) darkCount++;
      }
      final darkFrac = darkCount / zoneLen;
      final occlusionFired = _occlusion.push(darkFrac, zoneMean.toDouble());

      // ── PRIMARY DETECTOR: trained insertion-action model ─────────────────
      // Trained on 36 real insertion videos + hard negatives; validated at
      // 36/36 detections with 0 false fires. The arrow-occlusion cycle is
      // an OR-fused second trigger (either one counts, shared cooldown).
      _model.push(_changedFraction, frameDown, frameCorner);
      if (_model.isReady && !_inCooldown()) {
        final p = _model.score();
        lastProbability = p;
        _dbgFrame++;
        if (_dbgFrame % 15 == 0) {
          debugPrint('[Model] p=${p.toStringAsFixed(2)} '
              'zone=${_changedFraction.toStringAsFixed(3)} '
              'dark=${darkFrac.toStringAsFixed(2)} '
              'corner=${frameCorner.toStringAsFixed(3)}');
        }
        // ── COUNT DECISION ──────────────────────────────────────────────
        // The printed-arrow occlusion is the ONLY counting trigger:
        //   • armed only while the AR arrow is locked on the slot
        //   • requires real motion in the zone at hide-time (not a shadow)
        // The AI model no longer fires counts — field testing showed it
        // trips on APPROACH motion (bottle nearing the slot), causing
        // counts BEFORE the actual insertion. It remains as a live
        // diagnostic (the AI % readout and [Model] logs).
        final shouldCount = occlusionFired &&
            occlusionArmed &&
            _changedFraction >= 0.03;
        if (occlusionFired && !shouldCount) {
          debugPrint('[Occlusion] hide detected but not counted '
              '(armed=$occlusionArmed zone=${_changedFraction.toStringAsFixed(3)})');
        }
        if (shouldCount) {
          debugPrint('[Occlusion] Printed arrow hidden by bottle → count');
          _lastCount = DateTime.now();
          _model.reset(); // fresh window for the next insertion
          _occlusion.reset();
          final durationMs = _attemptStart != null
              ? DateTime.now().difference(_attemptStart!).inMilliseconds
              : 0;
          _onAttemptComplete?.call(InsertionAttemptResult(
            counted:            true,
            rejectedReason:     null,
            peakChangeFraction: _changedFraction,
            peakDownwardScore:  frameDown,
            avgCornerMotion:    frameCorner,
            durationMs:         durationMs,
          ));
          _onMotionDetected();
          _previousSample = sample;
          return;
        }
      }

      if (_changedFraction < _minChangeFraction) {
        final shouldCount = _state == _PassState.inside || _state == _PassState.exiting;
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
          final avgCornerMotion =
              _cornerMotionCount > 0 ? _cornerMotionSum / _cornerMotionCount : 0.0;

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
          final requiredRatio = soundConfirmed ? 1.3 : 2.2;

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
            counted:            counted,
            rejectedReason:     rejectedReason,
            peakChangeFraction: _peakChangeFraction,
            peakDownwardScore:  _peakDownwardScore,
            avgCornerMotion:    avgCornerMotion,
            durationMs:         durationMs,
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
          _rowHistory[b] = _rowHistory[b] * 0.6 + (bandMotion[b] / bandMax) * 0.4;
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
          if (relPos < 0.55 && _changedFraction > _minChangeFraction * 0.8) { // wider zone for open-top bins
            _state = _PassState.entering;
            // Fresh attempt — clear any stale tracking from a prior attempt.
            _cornerMotionSum = 0;
            _cornerMotionCount = 0;
            _peakChangeFraction = _changedFraction;
            _peakDownwardScore  = 0;
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
      return _extractBGRA(image, left, top, regionWidth, regionHeight, width, height);
    }

    return _extractYUV(image, left, top, regionWidth, regionHeight, width, height);
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
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
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
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
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