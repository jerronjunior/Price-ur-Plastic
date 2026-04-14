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
  static const int    _minPixels = 20;

  // Adaptive threshold: pixel must be this much brighter than scene mean
  static const double _deltaY = 8.0;

  // Lock mechanism
  static const int    _lockFrames  = 4;
  static const double _seekAlpha   = 0.35;
  static const double _lockedAlpha = 0.05;
  static const double _unlockDist  = 0.20;

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

    // Always use the back camera — prefer back, fall back to first available
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cam = CameraController(
      camera,
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

      // ── ACCURATE coordinate mapping: camera → screen ────────────────────────
      // The preview uses BoxFit.cover inside a SizedBox(width, width/aspectRatio).
      // FittedBox.cover scales that to fill the screen, cropping the sides.
      // Scale factor s = screenHeight × aspectRatio / screenWidth.
      // A camera normalised coord (0–1) maps to screen as:
      //   screenX = screenW × (s × (normX − 0.5) + 0.5)   ← horizontal: scaled
      //   screenY = normY × screenH                        ← vertical: unchanged
      final double camAspect = _cam!.value.aspectRatio;          // width/height
      final double s = (size.height * camAspect / size.width)    // cover scale
          .clamp(1.0, 6.0);

      final double targetX = (size.width  * (s * (_tracker.slotNormX - 0.5) + 0.5))
          .clamp(size.width * 0.05, size.width  * 0.95);
      final double targetY = (_tracker.slotNormY * size.height)
          .clamp(size.height * 0.05, size.height * 0.68);

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

        // ── Game-style rotating 3D arrow ──────────────────────────────────
        // The arrow PIVOTS at the screen center-bottom area.
        // TIP always points at the bin slot (tracked).
        // TAIL swings opposite: camera moves right → slot moves left in
        // frame → tip rotates left → tail swings right.  Exactly like a
        // game navigation compass arrow.
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (context, _) {
            // Arrow pivot: fixed point on screen the arrow rotates around
            final Offset pivot = Offset(size.width * 0.50, size.height * 0.72);
            // Angle from pivot to target (bin slot)
            final double angle = atan2(
              targetY - pivot.dy,
              targetX - pivot.dx,
            ) + pi / 2; // +pi/2 because arrow art points UP (north)

            return CustomPaint(
              size: size,
              painter: _GameArrowPainter(
                pivot:       pivot,
                angle:       angle,
                animValue:   _dotCtrl.value,
                isDetecting: _engine.state == _FlapState.open,
                hasLock:     _tracker.hasLock,
                target:      Offset(targetX, targetY),
              ),
            );
          },
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
// _GameArrowPainter
//
// Draws a 3D upward-pointing arrow (like the reference image) that ROTATES
// around a fixed pivot to always aim its tip at the bin slot.
//
// BEHAVIOR:
//   • Pivot point is fixed at screen center-bottom area.
//   • Angle = atan2(slot - pivot) + π/2  (because arrow art points UP/north).
//   • Camera moves RIGHT → slot moves LEFT in frame → angle rotates CCW →
//     tip swings left, tail swings right.  Exactly like a game compass.
//
// 3D ARROW DESIGN (matches the reference image):
//
//         ▲   ← tip (points at slot)
//        ╱ ╲
//       ╱   ╲  ← triangle head (front face, vivid red)
//      ╱_____╲
//      |     |  ← trapezoid body (narrower at top, wider at bottom)
//      |     |
//      |_____|
//      ▔▔▔▔▔▔▔  ← flat base rectangle
//      ░░░░░░░  ← 3D bottom face (dark, offset down-right)
//
//   LEFT FACE:  dark strip visible on the left edge of body+base
//   BOTTOM:     dark rectangle below the base (3D platform effect)
//   HIGHLIGHT:  bright strip on right edge of head (light source from right)
//
// STATES:
//   No lock  → 35% opacity, slow wobble animation
//   Locked   → full opacity, stable, "SLOT" label at tip
//   Detecting → orange color, pulsing scale, "INSERT!" label
// ══════════════════════════════════════════════════════════════════════════════
class _GameArrowPainter extends CustomPainter {
  const _GameArrowPainter({
    required this.pivot,
    required this.angle,
    required this.animValue,
    required this.isDetecting,
    required this.hasLock,
    required this.target,
  });

  final Offset pivot;
  final double angle;       // radians: angle to rotate the arrow
  final double animValue;   // 0→1 animation cycle
  final bool   isDetecting;
  final bool   hasLock;
  final Offset target;      // screen position of bin slot (for label placement)

  static const Color _red       = Color(0xFFE53935);
  static const Color _orange    = Color(0xFFFF6B35);
  static const Color _darkRed   = Color(0xFF7B0000);
  static const Color _darkest   = Color(0xFF3E0000);
  static const Color _highlight = Color(0xFFFF8A80);

  Color get _main  => isDetecting ? _orange : _red;
  Color get _dark  => isDetecting ? const Color(0xFF8B3000) : _darkRed;
  Color get _edge  => isDetecting ? const Color(0xFF3E1500) : _darkest;
  double get _globalOpacity => hasLock ? 0.93 : 0.38;

  @override
  void paint(Canvas canvas, Size size) {
    // ── Pulsing scale when detecting ─────────────────────────────────────────
    final double pulseScale = isDetecting
        ? 1.0 + sin(animValue * pi * 4) * 0.06
        : 1.0;

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    // Strictly track the angle — no wobble, accuracy is more important
    canvas.rotate(angle);
    canvas.scale(pulseScale, pulseScale);

    _drawArrow(canvas);

    canvas.restore();

    // ── Target ring at the slot position ─────────────────────────────────────
    _drawTargetRing(canvas);
  }

  // ── Arrow drawn pointing UP, centered at (0,0) ───────────────────────────
  void _drawArrow(Canvas canvas) {
    // Arrow dimensions (all relative to center at origin)
    const double arrowTotalH = 160.0;
    const double headH       = 62.0;  // triangle head height
    const double headHW      = 52.0;  // head half-width at shoulder
    const double bodyTopHW   = 22.0;  // body half-width at top
    const double bodyBotHW   = 28.0;  // body half-width at bottom
    const double bodyH       = 72.0;  // body trapezoid height
    const double baseH       = 18.0;  // base rectangle height
    const double depth       = 8.0;   // 3D depth offset

    // Y coordinates (0 = pivot center, negative = upward = toward tip)
    // Arrow is centered vertically: tip at -arrowTotalH*0.6, base at +arrowTotalH*0.4
    const double tipY       = -arrowTotalH * 0.60;
    const double shoulderY  = tipY + headH;
    const double bodyBotY   = shoulderY + bodyH;
    const double baseBotY   = bodyBotY + baseH;

    final double o = _globalOpacity; // opacity shorthand

    // ── 3D BACK FACES (drawn first — behind the front face) ──────────────────

    // Bottom face of base (3D platform, visible below)
    final Path bottomFace = Path()
      ..moveTo(-bodyBotHW,          baseBotY)
      ..lineTo( bodyBotHW,          baseBotY)
      ..lineTo( bodyBotHW + depth,  baseBotY + depth)
      ..lineTo(-bodyBotHW + depth,  baseBotY + depth)
      ..close();
    canvas.drawPath(bottomFace, Paint()..color = _edge.withOpacity(0.85 * o));

    // Left side face of body (dark strip on the left)
    final Path leftFace = Path()
      ..moveTo(-bodyTopHW,          shoulderY)
      ..lineTo(-bodyTopHW - depth,  shoulderY + depth)
      ..lineTo(-bodyBotHW - depth,  bodyBotY  + depth)
      ..lineTo(-bodyBotHW,          bodyBotY)
      ..close();
    canvas.drawPath(leftFace, Paint()..color = _dark.withOpacity(0.80 * o));

    // Left side face of base
    final Path leftBase = Path()
      ..moveTo(-bodyBotHW,          bodyBotY)
      ..lineTo(-bodyBotHW - depth,  bodyBotY  + depth)
      ..lineTo(-bodyBotHW - depth,  baseBotY  + depth)
      ..lineTo(-bodyBotHW,          baseBotY)
      ..close();
    canvas.drawPath(leftBase, Paint()..color = _edge.withOpacity(0.80 * o));

    // ── FRONT FACE — main red arrow shape ────────────────────────────────────
    final Path front = Path()
      // Head triangle
      ..moveTo(0,          tipY)          // tip (top point)
      ..lineTo( headHW,    shoulderY)     // right shoulder
      ..lineTo( bodyTopHW, shoulderY)     // right neck
      // Body right side
      ..lineTo( bodyBotHW, bodyBotY)      // right body bottom
      // Base
      ..lineTo( bodyBotHW, baseBotY)      // right base bottom
      ..lineTo(-bodyBotHW, baseBotY)      // left base bottom
      // Body left side
      ..lineTo(-bodyBotHW, bodyBotY)      // left body bottom
      ..lineTo(-bodyTopHW, shoulderY)     // left neck
      ..lineTo(-headHW,    shoulderY)     // left shoulder
      ..close();

    canvas.drawPath(front, Paint()..color = _main.withOpacity(0.96 * o));

    // ── RIGHT HIGHLIGHT on head (light from right) ────────────────────────────
    final Path rightHl = Path()
      ..moveTo(0,        tipY)
      ..lineTo(headHW,   shoulderY)
      ..lineTo(headHW * 0.55, shoulderY)
      ..close();
    canvas.drawPath(
      rightHl,
      Paint()..color = _highlight.withOpacity(0.35 * o),
    );

    // ── INNER BODY SHADING — slight darker center of body for depth ───────────
    // Subtle gradient effect by drawing a narrow darker strip down the center
    final Path centerShade = Path()
      ..moveTo(-4, shoulderY)
      ..lineTo( 4, shoulderY)
      ..lineTo( bodyBotHW * 0.25, baseBotY)
      ..lineTo(-bodyBotHW * 0.25, baseBotY)
      ..close();
    canvas.drawPath(
      centerShade,
      Paint()..color = _dark.withOpacity(0.12 * o),
    );

    // ── OUTLINE stroke for crispness ─────────────────────────────────────────
    canvas.drawPath(
      front,
      Paint()
        ..color = _edge.withOpacity(0.40 * o)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  // ── Target ring drawn at the actual slot position ─────────────────────────
  void _drawTargetRing(Canvas canvas) {
    final double pulse = isDetecting
        ? 0.5 + sin(animValue * pi * 5) * 0.5
        : hasLock
            ? 0.5 + sin(animValue * pi * 2) * 0.3
            : 0.2;

    final Color rc = isDetecting ? _orange : _red;
    final double r = 20.0 + pulse * 8;
    final double o = _globalOpacity;

    // Ring
    canvas.drawCircle(target, r,
      Paint()
        ..color = rc.withOpacity((0.78 + pulse * 0.22) * o)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hasLock ? 2.8 : 1.5);

    // Center dot
    canvas.drawCircle(target, hasLock ? 4.5 : 2.5,
      Paint()..color = rc.withOpacity(0.95 * o));

    // Crosshair
    final double arm = hasLock ? 13.0 : 8.0;
    const double gap = 6.0;
    final Paint lp = Paint()
      ..color = rc.withOpacity(0.80 * o)
      ..strokeWidth = hasLock ? 2.0 : 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(target.dx, target.dy - gap),
        Offset(target.dx, target.dy - gap - arm), lp);
    canvas.drawLine(Offset(target.dx, target.dy + gap),
        Offset(target.dx, target.dy + gap + arm), lp);
    canvas.drawLine(Offset(target.dx - gap, target.dy),
        Offset(target.dx - gap - arm, target.dy), lp);
    canvas.drawLine(Offset(target.dx + gap, target.dy),
        Offset(target.dx + gap + arm, target.dy), lp);

    // Label
    if (hasLock) {
      final String label = isDetecting ? 'INSERT!' : 'SLOT';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: rc.withOpacity(0.85 * o),
            fontSize: isDetecting ? 12 : 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 5)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(target.dx - tp.width / 2, target.dy + r + 8));
    }
  }

  @override
  bool shouldRepaint(_GameArrowPainter old) =>
      old.pivot       != pivot       ||
      old.angle       != angle       ||
      old.animValue   != animValue   ||
      old.isDetecting != isDetecting ||
      old.hasLock     != hasLock     ||
      old.target      != target;
}