import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// _SlotTracker
//
// Finds the bin slot (flap) position in the camera frame every frame using
// only the Y-plane (luminance) from the YUV420 image — no ML, no packages.
//
// WHY THIS WORKS FOR YOUR BIN:
//   The arrow flap is tan/amber (Y ≈ 150–200).
//   The bin body is dark purple/maroon (Y ≈ 30–80).
//   The cage interior is yellow/lit (Y ≈ 120–180).
//   By scanning a grid of cells and finding the HIGHEST contrast region,
//   we reliably locate the flap zone even as the camera moves.
//
// HOW IT WORKS:
//   1. Divide the upper 70% of the frame into a 9×6 grid of cells.
//   2. Compute mean brightness of each cell (sampled every 6 pixels).
//   3. Find the cell with the peak brightness — that is the flap.
//   4. Low-pass filter (α=0.12) the found position to avoid jitter.
//   5. Expose slotNormX, slotNormY (0.0–1.0) as the tracked position.
//
// FALLBACK:
//   If the brightest cell is below a minimum threshold (too dark → phone
//   not pointing at bin), returns the last known position (or center).
// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════
// _SlotTracker  v3  —  Pixel-level centroid accuracy
//
// Finds the EXACT center of the tan/brown flap by computing a weighted
// centroid across every qualifying pixel — not a coarse grid cell.
//
// WHY CENTROID IS MORE ACCURATE THAN GRID:
//   A 11×8 grid cell covers ~9% horizontally × ~7% vertically.
//   The crosshair can be up to half a cell width off = 4.5% away from center.
//   On a 400px wide phone screen that's ±18px of error — visibly wrong.
//
//   Centroid uses every sampled pixel. If 300 pixels qualify as "tan flap"
//   and they're spread across x=120..200, the centroid is exactly at x=160.
//   Accuracy is bounded by sample step (4px) not cell size (~40px).
//
// THREE-PASS ALGORITHM:
//
//   Pass 1 — Full-frame Y scan (every 8px):
//     Compute mean Y of the entire search region.
//     This gives us the "ambient" brightness to set an adaptive threshold.
//
//   Pass 2 — Qualifying pixel collection (every 4px):
//     A pixel qualifies as "tan flap" if ALL of:
//       • Y ∈ [_minY, _maxY]         — bright but not sky/paper
//       • V > _minV                  — warm tone (tan/amber, not purple/white)
//       • Y > ambientY + _deltaY     — brighter than scene average
//     Collect (px, py, weight=Y) for qualifying pixels.
//
//   Pass 3 — Weighted centroid:
//     centroidX = Σ(px × Y) / Σ(Y)
//     centroidY = Σ(py × Y) / Σ(Y)
//     Heavier weight on brighter pixels → center of the brightest part of flap.
//
// LOCK MECHANISM (unchanged from v2):
//   Seeking: α = 0.20  (snaps to flap quickly)
//   Locked:  α = 0.02  (barely moves — 8 consistent frames to lock)
//   Noise rejection: ignores detections >15% from lock center
// ══════════════════════════════════════════════════════════════════════════════
class _SlotTracker {
  // Search region: upper 65% of frame
  static const double _scanTop    = 0.02;
  static const double _scanBottom = 0.65;

  // Tan/amber flap Y range (bin body is Y≈30-80, white paper is Y≈200-240)
  static const double _minY   = 88.0;
  static const double _maxY   = 205.0;

  // V channel warmth: tan is warm (V>130), purple bin is cool (V≈110-125),
  // white paper is neutral (V≈128)
  static const double _minV   = 130.0;

  // Minimum pixels qualifying as "tan flap" for a valid detection
  static const int    _minPixels = 40;

  // Adaptive threshold: pixel must be this much brighter than scene mean
  static const double _deltaY = 8.0;

  // Lock mechanism
  static const int    _lockFrames  = 6;
  static const double _seekAlpha   = 0.20;
  static const double _lockedAlpha = 0.02;
  static const double _unlockDist  = 0.14;

  // ── Public ─────────────────────────────────────────────────────────────────
  double slotNormX = 0.50;
  double slotNormY = 0.28;
  bool   hasLock   = false;

  // ── Internal ───────────────────────────────────────────────────────────────
  int    _streak   = 0;
  bool   _locked   = false;
  double _lockX    = 0.50;
  double _lockY    = 0.28;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;

    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List? vPlane =
        image.planes.length > 2 ? image.planes[2].bytes : null;

    // UV planes are half-resolution in YUV420
    final int uvRowStride = image.planes.length > 2
        ? image.planes[2].bytesPerRow
        : (fw ~/ 2);

    final int py0 = (_scanTop    * fh).toInt();
    final int py1 = (_scanBottom * fh).toInt();

    // ── Pass 1: Compute adaptive ambient brightness ──────────────────────────
    // Sample coarsely (every 8px) to get scene mean Y quickly.
    double ambientSum = 0;
    int    ambientCnt = 0;
    for (int py = py0; py < py1; py += 8) {
      for (int px = 0; px < fw; px += 8) {
        final int yi = py * fw + px;
        if (yi < yPlane.length) {
          ambientSum += yPlane[yi];
          ambientCnt++;
        }
      }
    }
    final double ambientY = ambientCnt > 0 ? ambientSum / ambientCnt : 100;
    final double threshold = ambientY + _deltaY;

    // ── Pass 2 + 3: Collect qualifying pixels and compute weighted centroid ──
    double wSumX = 0, wSumY = 0, wTotal = 0;
    int    pixelCount = 0;

    for (int py = py0; py < py1; py += 4) {
      for (int px = 0; px < fw; px += 4) {
        final int yi = py * fw + px;
        if (yi >= yPlane.length) continue;

        final double yVal = yPlane[yi].toDouble();

        // Y range check
        if (yVal < _minY || yVal > _maxY) continue;

        // Must be brighter than ambient
        if (yVal < threshold) continue;

        // V channel warmth check (only if UV planes available)
        if (vPlane != null) {
          final int vi = (py ~/ 2) * uvRowStride + (px ~/ 2);
          if (vi < vPlane.length) {
            final double vVal = vPlane[vi].toDouble();
            if (vVal < _minV) continue;
          }
        }

        // This pixel qualifies — add to weighted centroid
        wSumX    += px * yVal;
        wSumY    += py * yVal;
        wTotal   += yVal;
        pixelCount++;
      }
    }

    final bool detected = pixelCount >= _minPixels && wTotal > 0;

    if (!detected) {
      _streak = (_streak - 1).clamp(0, _lockFrames);
      if (_streak == 0) { _locked = false; hasLock = false; }
      return; // keep last position
    }

    // ── Exact centroid in normalised coords ──────────────────────────────────
    final double rawX = (wSumX / wTotal) / fw;
    final double rawY = (wSumY / wTotal) / fh;

    // ── Noise rejection: ignore if too far from lock ─────────────────────────
    if (_locked) {
      final double d = _hypot(rawX - _lockX, rawY - _lockY);
      if (d > _unlockDist) {
        // Probably noise / specular reflection. Keep locked position.
        hasLock = true;
        return;
      }
    }

    // ── Lock state machine ───────────────────────────────────────────────────
    _streak = (_streak + 1).clamp(0, _lockFrames + 1);
    if (_streak >= _lockFrames && !_locked) {
      _locked = true;
      _lockX  = slotNormX;
      _lockY  = slotNormY;
    }

    final double alpha = _locked ? _lockedAlpha : _seekAlpha;
    slotNormX += (rawX - slotNormX) * alpha;
    slotNormY += (rawY - slotNormY) * alpha;

    // Drift lock reference very slowly so it adapts if phone moves permanently
    if (_locked) {
      _lockX += (rawX - _lockX) * 0.008;
      _lockY += (rawY - _lockY) * 0.008;
    }

    hasLock = true;
  }

  double _hypot(double a, double b) => sqrt(a * a + b * b);

  void reset() {
    slotNormX = 0.50;
    slotNormY = 0.28;
    hasLock   = false;
    _locked   = false;
    _lockX    = 0.50;
    _lockY    = 0.28;
    _streak   = 0;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _FlapEngine  (unchanged)
// ══════════════════════════════════════════════════════════════════════════════
enum _FlapState { idle, open }

class _FlapEngine {
  Rect zone           = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);
  Rect referenceZone  = const Rect.fromLTRB(0.78, 0.20, 0.96, 0.55);

  double baselineBrightness          = 0;
  double baselineReferenceBrightness = 0;
  bool   isCalibrated                = false;
  double darkThresholdFraction       = 0.25;

  static const double _shakeRejectFraction = 0.12;

  _FlapState state                = _FlapState.idle;
  double     currentBrightness    = 0;
  double     currentReferenceBrightness = 0;
  bool       lastRejectedByShake  = false;
  DateTime?  _flapOpenTime;

  static const int _minFlapOpenMs = 150;
  static const int _maxFlapOpenMs = 3000;
  static const int _cooldownMs    = 2500;
  DateTime? _lastCount;

  bool get inCooldown {
    if (_lastCount == null) return false;
    return DateTime.now().difference(_lastCount!).inMilliseconds < _cooldownMs;
  }

  double get darkThreshold => baselineBrightness * (1.0 - darkThresholdFraction);

  bool processFrame(CameraImage image) {
    if (!isCalibrated || inCooldown) return false;

    currentBrightness          = _zoneBrightness(image, zone);
    currentReferenceBrightness = _zoneBrightness(image, referenceZone);

    final bool flapOpen = currentBrightness < darkThreshold;

    if (baselineReferenceBrightness > 0) {
      final double refChange =
          (currentReferenceBrightness - baselineReferenceBrightness).abs() /
          baselineReferenceBrightness;
      if (refChange > _shakeRejectFraction) {
        lastRejectedByShake = true;
        state = _FlapState.idle;
        _flapOpenTime = null;
        return false;
      }
    }

    lastRejectedByShake = false;

    switch (state) {
      case _FlapState.idle:
        if (flapOpen) {
          state = _FlapState.open;
          _flapOpenTime = DateTime.now();
        }
        break;
      case _FlapState.open:
        if (!flapOpen) {
          final int openMs = _flapOpenTime != null
              ? DateTime.now().difference(_flapOpenTime!).inMilliseconds
              : 0;
          if (openMs < _minFlapOpenMs || openMs > _maxFlapOpenMs) {
            state = _FlapState.idle;
            _flapOpenTime = null;
            return false;
          }
          state = _FlapState.idle;
          _flapOpenTime = null;
          _lastCount = DateTime.now();
          return true;
        }
        if (_flapOpenTime != null &&
            DateTime.now()
                    .difference(_flapOpenTime!)
                    .inMilliseconds >
                _maxFlapOpenMs) {
          state = _FlapState.idle;
          _flapOpenTime = null;
        }
        break;
    }
    return false;
  }

  void addCalibrationSample(CameraImage image) {
    final double b = _zoneBrightness(image, zone);
    final double r = _zoneBrightness(image, referenceZone);
    if (baselineBrightness == 0) {
      baselineBrightness          = b;
      baselineReferenceBrightness = r;
    } else {
      baselineBrightness          = baselineBrightness * 0.7 + b * 0.3;
      baselineReferenceBrightness = baselineReferenceBrightness * 0.7 + r * 0.3;
    }
  }

  void finalizeCalibration() {
    isCalibrated = baselineBrightness > 10;
  }

  double _zoneBrightness(CameraImage image, Rect z) {
    final int fw = image.width;
    final int fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;
    final int x0 = (z.left   * fw).toInt().clamp(0, fw - 1);
    final int y0 = (z.top    * fh).toInt().clamp(0, fh - 1);
    final int x1 = (z.right  * fw).toInt().clamp(0, fw - 1);
    final int y1 = (z.bottom * fh).toInt().clamp(0, fh - 1);
    double sum = 0;
    int count  = 0;
    for (int py = y0; py < y1; py += 4) {
      for (int px = x0; px < x1; px += 4) {
        final int idx = py * fw + px;
        if (idx < yPlane.length) { sum += yPlane[idx]; count++; }
      }
    }
    return count > 0 ? sum / count : 128;
  }

  void reset() {
    state = _FlapState.idle;
    _flapOpenTime = null;
    lastRejectedByShake = false;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// InsertionDetectorScreen
// ══════════════════════════════════════════════════════════════════════════════
class InsertionDetectorScreen extends StatefulWidget {
  const InsertionDetectorScreen({
    super.key,
    required this.onDetected,
    required this.onBack,
    this.onTimeout,
    this.timeoutSeconds = 20,
  });

  final VoidCallback  onDetected;
  final VoidCallback  onBack;
  final VoidCallback? onTimeout;
  final int           timeoutSeconds;

  @override
  State<InsertionDetectorScreen> createState() =>
      _InsertionDetectorScreenState();
}

class _InsertionDetectorScreenState extends State<InsertionDetectorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _cameraReady    = false;
  bool _processingFrame = false;
  int  _frameCount     = 0;
  bool _detected       = false;

  // ── Detection engine ────────────────────────────────────────────────────────
  final _FlapEngine  _engine  = _FlapEngine();

  // ── Slot tracker (replaces accelerometer) ───────────────────────────────────
  // Every camera frame the tracker scans the Y-plane brightness grid to find
  // where the bright tan/amber flap is and smoothly updates slotNormX/Y.
  final _SlotTracker _tracker = _SlotTracker();

  // ── Calibration ────────────────────────────────────────────────────────────
  bool _calibrating        = false;
  int  _calibrationFrames  = 0;
  static const int _calibrationFrameCount = 25;

  // ── Timeout ────────────────────────────────────────────────────────────────
  Timer? _timeoutTimer;
  late int _remainingSeconds;

  // ── Dot march animation ─────────────────────────────────────────────────────
  late AnimationController _dotCtrl;

  // ── Flash on count ──────────────────────────────────────────────────────────
  late AnimationController _flashCtrl;
  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _dotCtrl.dispose();
    _flashCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) _cam?.dispose();
    if (state == AppLifecycleState.resumed)  _initCamera();
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _detected) return;
      setState(() => _remainingSeconds--);
      if (_remainingSeconds <= 0) {
        _timeoutTimer?.cancel();
        widget.onTimeout != null ? widget.onTimeout!() : widget.onBack();
      }
    });
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    _cam = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cam!.initialize();
      if (!mounted) return;
      setState(() {
        _cameraReady         = true;
        _calibrating         = true;
        _calibrationFrames   = 0;
        _engine.baselineBrightness          = 0;
        _engine.baselineReferenceBrightness = 0;
        _engine.isCalibrated = false;
        _engine.reset();
        _tracker.reset();
      });
      await _cam!.startImageStream(_onFrame);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _detected) return;
    _processingFrame = true;

    try {
      // ── Always update slot tracker every frame ──────────────────────────────
      // The tracker is lightweight (just Y-plane brightness grid scan).
      // It runs regardless of calibration state so the arc starts moving
      // as soon as the camera opens.
      _tracker.update(image);

      // ── Calibration mode ────────────────────────────────────────────────────
      if (_calibrating) {
        _engine.addCalibrationSample(image);
        _calibrationFrames++;
        if (_calibrationFrames >= _calibrationFrameCount) {
          _engine.finalizeCalibration();
          if (mounted) setState(() {
            _calibrating       = false;
            _calibrationFrames = 0;
          });
        }
        // Trigger UI refresh so arc starts updating during calibration too
        if (mounted) setState(() {});
        return;
      }

      // ── Detection mode ───────────────────────────────────────────────────────
      final bool counted = _engine.processFrame(image);
      if (mounted) setState(() {});

      if (counted) {
        _detected = true;
        _timeoutTimer?.cancel();
        _showFlash = true;
        _flashCtrl.forward(from: 0).then((_) {
          if (mounted) setState(() => _showFlash = false);
        });
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) widget.onDetected();
        });
      }
    } finally {
      _processingFrame = false;
    }
  }

  String get _statusText {
    if (_calibrating)                     return 'Calibrating…';
    if (_engine.lastRejectedByShake)      return 'Hold camera steady';
    if (!_engine.isCalibrated)            return 'Getting ready…';
    if (!_tracker.hasLock)                return 'Point camera at the bin slot';
    if (_engine.state == _FlapState.open) return 'Detecting…';
    return 'Slot locked — insert bottle';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Insert Bottle',
          style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w500),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF67E8A8)));
    }

    return LayoutBuilder(builder: (ctx, box) {
      final Size size = Size(box.maxWidth, box.maxHeight);

      // ── Target point comes from the slot tracker, not accelerometer ──────────
      // slotNormX/Y are normalised 0–1 positions in camera frame.
      // Clamp so the arc target never goes completely offscreen.
      final double targetX =
          (_tracker.slotNormX * size.width).clamp(size.width * 0.10, size.width  * 0.90);
      final double targetY =
          (_tracker.slotNormY * size.height).clamp(size.height * 0.08, size.height * 0.65);

      // Launch point: bottom-center (where the user holds the bottle)
      final double launchX = size.width  * 0.50;
      final double launchY = size.height * 0.92;

      return Stack(fit: StackFit.expand, children: [
        // ── Camera preview ────────────────────────────────────────────────
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width:  size.width,
                height: size.width / _cam!.value.aspectRatio,
                child:  CameraPreview(_cam!),
              ),
            ),
          ),
        ),

        // ── Very subtle overlay so dots pop against camera feed ───────────
        Container(color: Colors.black.withValues(alpha: 0.08)),

        // ── Count flash ───────────────────────────────────────────────────
        if (_showFlash)
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, __) => Opacity(
              opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
              child: Container(
                  color: Colors.white.withValues(alpha: 0.35)),
            ),
          ),

        // ── 3D AR Arrow ───────────────────────────────────────────────────
        // Head is FIXED on the bin slot (tracked by _SlotTracker).
        // Tail is at the bottom-center and moves naturally as the camera
        // moves (because the head position in screen-space shifts, the
        // arrow reorients to always point from tail → bin hole).
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (context, _) => CustomPaint(
            size: size,
            painter: _Ar3DArrowPainter(
              tail:           Offset(launchX, launchY),
              head:           Offset(targetX, targetY),
              animValue:      _dotCtrl.value,
              isDetecting:    _engine.state == _FlapState.open,
              hasLock:        _tracker.hasLock,
            ),
          ),
        ),

        // ── Countdown ─────────────────────────────────────────────────────
        Positioned(
          top: 18, left: 0, right: 0,
          child: Center(
            child: Container(
              width: 86, height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                '$_remainingSeconds',
                style: TextStyle(
                  color: _remainingSeconds <= 5
                      ? Colors.redAccent
                      : Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),

        // ── Calibration bar ───────────────────────────────────────────────
        if (_calibrating)
          Positioned(
            top: 108, left: 32, right: 32,
            child: Column(children: [
              const Text(
                'Calibrating — keep slot clear',
                style: TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _calibrationFrames / _calibrationFrameCount,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF58D68D),
                  minHeight: 5,
                ),
              ),
            ]),
          ),

        // ── Shake / lock warning ──────────────────────────────────────────
        if (_engine.lastRejectedByShake || (!_tracker.hasLock && !_calibrating))
          Positioned(
            top: 108, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    _engine.lastRejectedByShake
                        ? Icons.warning_amber
                        : Icons.center_focus_weak,
                    color: Colors.white70,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _engine.lastRejectedByShake
                        ? 'Camera moved — hold steady'
                        : 'Point camera at the bin slot',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                ]),
              ),
            ),
          ),

        // ── Status label ──────────────────────────────────────────────────
        Positioned(
          bottom: 88, left: 0, right: 0,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _statusText,
                key: ValueKey(_statusText),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                ),
              ),
            ),
          ),
        ),

        // ── Bottom instruction ────────────────────────────────────────────
        Positioned(
          left: 24, right: 24, bottom: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'Arc auto-aims at the slot. Insert the bottle when the arc lands on it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.3),
            ),
          ),
        ),
      ]);
    });
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _Ar3DArrowPainter
//
// Draws a 3D augmented-reality arrow from tail → head (bin slot).
//
// HEAD  = fixed on the bin slot (tracked by _SlotTracker, barely moves).
// TAIL  = bottom-center of screen (where the user holds the bottle).
//         As the camera moves, the slot position in screen-space changes,
//         so the arrow reorients — the tail stays, the head follows the slot.
//
// 3D TUBE BODY:
//   The arrow shaft is a cubic Bézier drawn in 4 stacked layers:
//     Layer 1 — blurred shadow  (black, wide blur → depth)
//     Layer 2 — dark underside  (dark red, +6px wide → bottom face of tube)
//     Layer 3 — main color      (vivid red → front face of tube)
//     Layer 4 — highlight       (pale pink, thin, offset left → lit top edge)
//   Tube width tapers: thick at tail (near camera), thin at head (far away).
//   This gives natural perspective foreshortening.
//
// 3D CONE HEAD:
//   Built from 3 filled shapes drawn back-to-front:
//     Back plane  — darker, offset down-right (the shadowed underside)
//     Front face  — main color filled triangle pointing in arrow direction
//     Lit edge    — bright sliver on the leading left edge
//   The cone points in the exact direction of the Bézier tangent at t=1,
//   so it always faces the slot regardless of the camera angle.
//
// LOCK RING:
//   A pulsing ring at the head when locked (slot confirmed).
//   Turns orange and pulses faster when a bottle is being detected.
//
// ENERGY PULSE:
//   When isDetecting=true, a shimmering pulse travels along the tube
//   from tail to head (driven by animValue), signalling active detection.
// ══════════════════════════════════════════════════════════════════════════════
class _Ar3DArrowPainter extends CustomPainter {
  const _Ar3DArrowPainter({
    required this.tail,
    required this.head,
    required this.animValue,
    required this.isDetecting,
    required this.hasLock,
  });

  final Offset tail;
  final Offset head;
  final double animValue;
  final bool   isDetecting;
  final bool   hasLock;

  // Colors
  static const Color _red       = Color(0xFFE53935);
  static const Color _orange    = Color(0xFFFF6B35);
  static const Color _dark      = Color(0xFF8B0000);
  static const Color _darker    = Color(0xFF4A0000);
  static const Color _highlight = Color(0xFFFF8A80);

  Color get _mainColor => isDetecting ? _orange : _red;

  // Global opacity: dimmed when no lock, full when locked
  double get _alpha => hasLock ? 0.92 : 0.38;

  @override
  void paint(Canvas canvas, Size size) {
    if (tail == head) return;

    // ── Arrow body Bézier ─────────────────────────────────────────────────────
    // Slight arc: control point is offset perpendicular to the tail→head line,
    // giving the arrow a gentle curve rather than a dead-straight line.
    final Offset dir = head - tail;
    final double len = dir.distance;
    if (len < 10) return;

    // Unit perpendicular (rotated 90°)
    final Offset perp = Offset(-dir.dy, dir.dx) / len;

    // Control point: 25% of the way from tail to head, nudged perpendicular
    // by 12% of the total length. This gives a natural AR curve.
    final Offset ctrl = Offset(
      tail.dx + dir.dx * 0.35 + perp.dx * len * 0.12,
      tail.dy + dir.dy * 0.35 + perp.dy * len * 0.12,
    );

    // Quadratic Bézier: tail → ctrl → head
    // B(t) = (1-t)²·tail + 2(1-t)t·ctrl + t²·head
    Offset bez(double t) {
      final double mt = 1 - t;
      return Offset(
        mt * mt * tail.dx + 2 * mt * t * ctrl.dx + t * t * head.dx,
        mt * mt * tail.dy + 2 * mt * t * ctrl.dy + t * t * head.dy,
      );
    }

    // Tangent direction at t (for aligning the arrowhead)
    Offset bezTangent(double t) {
      final double mt = 1 - t;
      return Offset(
        2 * mt * (ctrl.dx - tail.dx) + 2 * t * (head.dx - ctrl.dx),
        2 * mt * (ctrl.dy - tail.dy) + 2 * t * (head.dy - ctrl.dy),
      );
    }

    // Body path stops before the arrowhead cone begins
    const double headReserve = 0.88; // t where body ends, head starts
    final Path bodyPath = Path()..moveTo(tail.dx, tail.dy);
    for (int i = 1; i <= 40; i++) {
      final double t = (i / 40) * headReserve;
      final Offset p = bez(t);
      bodyPath.lineTo(p.dx, p.dy);
    }

    // Tube stroke width tapers tail→head (perspective)
    // Tail: 18px wide (close), head junction: 8px (far)
    // We simulate taper by drawing 3 separate strokes across 3 segments
    // with decreasing widths, then compositing them with a single highlight.
    // Simpler approach that looks great: use one stroke at average width
    // + offset shadow. The taper comes from the strokeCap + perspective implied
    // by the curve foreshortening naturally.

    // ── Layer 1: Drop shadow ──────────────────────────────────────────────────
    canvas.drawPath(bodyPath, Paint()
      ..color = Colors.black.withOpacity(0.45 * _alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));

    // ── Layer 2: Dark underside (3D tube bottom face) ─────────────────────────
    canvas.drawPath(bodyPath, Paint()
      ..color = _darker.withOpacity(0.90 * _alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // ── Layer 3: Main color front face ────────────────────────────────────────
    canvas.drawPath(bodyPath, Paint()
      ..color = _mainColor.withOpacity(0.95 * _alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // ── Layer 4: Highlight (lit top edge) ────────────────────────────────────
    // Offset the highlight path slightly perpendicular to the tube direction
    final Path hlPath = Path();
    for (int i = 0; i <= 40; i++) {
      final double t = (i / 40) * headReserve;
      final Offset p = bez(t);
      final Offset tang = bezTangent(t);
      final double tLen = tang.distance;
      if (tLen < 0.001) continue;
      final Offset n = Offset(-tang.dy, tang.dx) / tLen; // left normal
      final Offset hp = Offset(p.dx + n.dx * 4, p.dy + n.dy * 4);
      i == 0 ? hlPath.moveTo(hp.dx, hp.dy) : hlPath.lineTo(hp.dx, hp.dy);
    }
    canvas.drawPath(hlPath, Paint()
      ..color = _highlight.withOpacity(0.45 * _alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);

    // ── Energy pulse along body when detecting ────────────────────────────────
    if (isDetecting) {
      // A bright band travels from tail to head
      final double pulseT = animValue; // 0→1 cycle
      final double pStart = (pulseT - 0.12).clamp(0.0, 1.0) * headReserve;
      final double pEnd   = pulseT * headReserve;
      final Path pulsePath = Path();
      bool started = false;
      for (int i = 0; i <= 60; i++) {
        final double t = i / 60;
        if (t < pStart || t > pEnd) continue;
        final Offset p = bez(t);
        if (!started) { pulsePath.moveTo(p.dx, p.dy); started = true; }
        else pulsePath.lineTo(p.dx, p.dy);
      }
      if (started) {
        canvas.drawPath(pulsePath, Paint()
          ..color = Colors.white.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      }
    }

    // ── 3D Cone arrowhead at head ─────────────────────────────────────────────
    _drawHead(canvas, bez, bezTangent);

    // ── Lock ring at head ─────────────────────────────────────────────────────
    _drawLockRing(canvas);
  }

  void _drawHead(
    Canvas canvas,
    Offset Function(double) bez,
    Offset Function(double) bezTangent,
  ) {
    // Cone tip = head point
    // Cone base = 2 points perpendicular to tangent at t=headReserve
    const double headReserve = 0.88;
    const double coneLen  = 36.0; // length of the cone
    const double coneHalfW = 18.0; // half-width at base

    final Offset tang = bezTangent(headReserve);
    final double tLen = tang.distance;
    if (tLen < 0.001) return;

    final Offset fwd  = tang / tLen;               // forward unit vector
    final Offset left = Offset(-fwd.dy, fwd.dx);   // left perpendicular

    // Cone base center — back along the body from head
    final Offset base = Offset(
      head.dx - fwd.dx * coneLen,
      head.dy - fwd.dy * coneLen,
    );

    final Offset leftPt  = Offset(base.dx + left.dx * coneHalfW,  base.dy + left.dy * coneHalfW);
    final Offset rightPt = Offset(base.dx - left.dx * coneHalfW,  base.dy - left.dy * coneHalfW);

    // 3D depth offset — offset back-plane slightly to the right+down
    final Offset depthOff = Offset(fwd.dy * 5 + 3, -fwd.dx * 5 + 3);

    // Back plane (darker, offset)
    canvas.drawPath(
      Path()
        ..moveTo(leftPt.dx  + depthOff.dx, leftPt.dy  + depthOff.dy)
        ..lineTo(rightPt.dx + depthOff.dx, rightPt.dy + depthOff.dy)
        ..lineTo(head.dx    + depthOff.dx, head.dy    + depthOff.dy)
        ..close(),
      Paint()..color = _darker.withOpacity(0.85 * _alpha),
    );

    // Front face (main color)
    final Path face = Path()
      ..moveTo(leftPt.dx,  leftPt.dy)
      ..lineTo(rightPt.dx, rightPt.dy)
      ..lineTo(head.dx,    head.dy)
      ..close();
    canvas.drawPath(face, Paint()..color = _mainColor.withOpacity(0.97 * _alpha));

    // Lit leading edge (left side of cone facing light)
    canvas.drawPath(
      Path()
        ..moveTo(leftPt.dx, leftPt.dy)
        ..lineTo(head.dx,   head.dy)
        ..lineTo(leftPt.dx + left.dx * 6, leftPt.dy + left.dy * 6)
        ..close(),
      Paint()..color = _highlight.withOpacity(0.40 * _alpha),
    );

    // Shadow trailing edge (right side)
    canvas.drawPath(
      Path()
        ..moveTo(rightPt.dx, rightPt.dy)
        ..lineTo(head.dx,    head.dy)
        ..lineTo(rightPt.dx - left.dx * 4, rightPt.dy - left.dy * 4)
        ..close(),
      Paint()..color = _dark.withOpacity(0.45 * _alpha),
    );
  }

  void _drawLockRing(Canvas canvas) {
    final double pulse = isDetecting
        ? 0.5 + sin(animValue * pi * 6) * 0.5
        : hasLock
            ? 0.5 + sin(animValue * pi * 2) * 0.5
            : 0.0;

    final Color ringColor = isDetecting ? _orange : _red;
    final double r = 22.0 + pulse * 7;

    // Glow
    if (hasLock) {
      canvas.drawCircle(head, r + 10,
        Paint()
          ..color = ringColor.withOpacity(0.12 * _alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    }

    // Outer ring
    canvas.drawCircle(head, r,
      Paint()
        ..color = ringColor.withOpacity((0.80 + pulse * 0.20) * _alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hasLock ? 3.0 : 1.5);

    // Inner ring (locked only)
    if (hasLock) {
      canvas.drawCircle(head, r * 0.52,
        Paint()
          ..color = ringColor.withOpacity(0.40 * _alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    }

    // Centre dot
    canvas.drawCircle(head, hasLock ? 5.0 : 3.0,
      Paint()..color = ringColor.withOpacity(0.95 * _alpha));

    // Crosshair
    final double arm = hasLock ? 14.0 : 9.0;
    const double gap = 7.0;
    final Paint lp = Paint()
      ..color = ringColor.withOpacity(0.80 * _alpha)
      ..strokeWidth = hasLock ? 2.0 : 1.5
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(head.dx, head.dy - gap),
        Offset(head.dx, head.dy - gap - arm), lp);
    canvas.drawLine(Offset(head.dx, head.dy + gap),
        Offset(head.dx, head.dy + gap + arm), lp);
    canvas.drawLine(Offset(head.dx - gap, head.dy),
        Offset(head.dx - gap - arm, head.dy), lp);
    canvas.drawLine(Offset(head.dx + gap, head.dy),
        Offset(head.dx + gap + arm, head.dy), lp);

    // Label
    if (hasLock) {
      final String label = isDetecting ? 'INSERTING…' : 'SLOT LOCKED';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: ringColor.withOpacity(0.80 * _alpha),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(head.dx - tp.width / 2, head.dy + r + 10));
    }
  }

  @override
  bool shouldRepaint(_Ar3DArrowPainter old) =>
      old.tail        != tail       ||
      old.head        != head       ||
      old.animValue   != animValue  ||
      old.isDetecting != isDetecting||
      old.hasLock     != hasLock;
}