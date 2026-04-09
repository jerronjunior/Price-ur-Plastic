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
// _SlotTracker  v2
//
// Finds the bin hole (tan/brown flap with downward arrow) and LOCKS onto it.
//
// HOW IT FINDS THE FLAP:
//   The flap is the tan/amber square (~RGB 170,130,80) which in YUV420 means:
//     Y  ≈ 110–190  (bright relative to dark purple bin body Y ≈ 30–80)
//     U  ≈ 100–130  (mildly blue-shifted from neutral 128)
//     V  ≈ 140–170  (warm/red-shifted — characteristic of amber/tan)
//
//   Strategy: scan a 11×8 grid in the upper 60% of frame.
//   Score each cell using THREE criteria:
//     1. Y brightness is in the tan range (not too dark, not sky-white)
//     2. V channel (warmth) is elevated — tan is warmer than the purple bin
//     3. The cell has HIGH CONTRAST with its neighbors — the flap is a bright
//        square surrounded by the darker bin body
//   The cell with the highest combined score = the flap.
//
// LOCK MECHANISM:
//   • "Seeking" state: α = 0.18  (responsive, finds the flap quickly)
//   • "Locked" state:  α = 0.03  (barely moves — target stays on hole)
//   • Enters locked state after _lockFrames consecutive consistent detections
//   • Loses lock only if the best cell moves far from locked position
//
// RESULT:
//   slotNormX / slotNormY — normalized 0–1 position that stays FIXED on the
//   bin hole. The arc endpoint is this position. Only the arc path changes
//   as the camera moves.
// ══════════════════════════════════════════════════════════════════════════════
class _SlotTracker {
  static const int    _cols = 11;
  static const int    _rows = 8;

  // Only search the upper part of the frame (slot is in top half)
  static const double _scanTop    = 0.02;
  static const double _scanBottom = 0.62;

  // Y range for the tan flap: brighter than bin body, dimmer than sky/white
  static const double _minY = 90.0;
  static const double _maxY = 210.0;

  // V channel (warmth) threshold — tan/amber has V > neutral 128
  static const double _minV = 132.0;

  // Minimum contrast score (cell brightness vs surrounding average)
  static const double _minContrast = 12.0;

  // Frames of consistent detection before entering locked mode
  static const int _lockFrames = 8;

  // Alpha values
  static const double _seekAlpha   = 0.18;  // responsive when seeking
  static const double _lockedAlpha = 0.03;  // barely moves when locked

  // Max distance from lock position before losing lock (normalised)
  static const double _unlockDist = 0.18;

  // ── Public state ────────────────────────────────────────────────────────────
  double slotNormX = 0.50;
  double slotNormY = 0.28;
  bool   hasLock   = false;

  // ── Internal ────────────────────────────────────────────────────────────────
  int    _consistentFrames = 0;
  bool   _locked           = false;
  double _lockedX          = 0.50;
  double _lockedY          = 0.28;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;

    final Uint8List yPlane = image.planes[0].bytes;

    // U and V planes (present in YUV420 images)
    final Uint8List? uPlane = image.planes.length > 1 ? image.planes[1].bytes : null;
    final Uint8List? vPlane = image.planes.length > 2 ? image.planes[2].bytes : null;
    final int uvW = (fw / 2).toInt();  // U/V planes are half resolution

    final int y0scan = (_scanTop    * fh).toInt();
    final int y1scan = (_scanBottom * fh).toInt();

    final int cellW = (fw / _cols).toInt().clamp(1, fw);
    final int cellH = ((y1scan - y0scan) / _rows).toInt().clamp(1, fh);

    // Build brightness grid first (need neighbours for contrast)
    final List<double> grid    = List.filled(_cols * _rows, 0);
    final List<double> vGrid   = List.filled(_cols * _rows, 128);

    for (int r = 0; r < _rows; r++) {
      for (int c = 0; c < _cols; c++) {
        final int px0 = c * cellW;
        final int py0 = y0scan + r * cellH;
        final int px1 = (px0 + cellW).clamp(0, fw);
        final int py1 = (py0 + cellH).clamp(0, fh);

        double sumY = 0, sumV = 0;
        int cnt = 0;

        for (int py = py0; py < py1; py += 6) {
          for (int px = px0; px < px1; px += 6) {
            final int yi = py * fw + px;
            if (yi < yPlane.length) {
              sumY += yPlane[yi];
              // U/V index (half resolution, interleaved or planar)
              if (vPlane != null) {
                final int vi = (py ~/ 2) * uvW + (px ~/ 2);
                if (vi < vPlane.length) sumV += vPlane[vi];
              }
              cnt++;
            }
          }
        }

        if (cnt > 0) {
          grid[r * _cols + c]  = sumY / cnt;
          vGrid[r * _cols + c] = vPlane != null ? sumV / cnt : 145.0;
        }
      }
    }

    // Score each cell
    double bestScore = 0;
    int bestC = _cols ~/ 2;
    int bestR = 1;

    for (int r = 0; r < _rows; r++) {
      for (int c = 0; c < _cols; c++) {
        final double y = grid[r * _cols + c];
        final double v = vGrid[r * _cols + c];

        // 1. Y must be in tan range
        if (y < _minY || y > _maxY) continue;

        // 2. V channel must indicate warm/amber tone
        // (if UV planes not available, skip this filter)
        if (vPlane != null && v < _minV) continue;

        // 3. Contrast: how much brighter than the 4 adjacent cells?
        double neighborSum = 0;
        int    neighborCnt = 0;
        for (final int nr in [r - 1, r + 1]) {
          if (nr >= 0 && nr < _rows) {
            neighborSum += grid[nr * _cols + c];
            neighborCnt++;
          }
        }
        for (final int nc in [c - 1, c + 1]) {
          if (nc >= 0 && nc < _cols) {
            neighborSum += grid[r * _cols + nc];
            neighborCnt++;
          }
        }
        final double contrast = neighborCnt > 0
            ? y - (neighborSum / neighborCnt)
            : 0.0;

        if (contrast < _minContrast) continue;

        // Score = brightness contribution + warmth bonus + contrast
        final double score = y * 0.5 +
            (vPlane != null ? (v - 128) * 1.5 : 0) +
            contrast * 2.0;

        if (score > bestScore) {
          bestScore = score;
          bestC     = c;
          bestR     = r;
        }
      }
    }

    final bool detected = bestScore > 0;

    // Raw candidate position in normalised coords
    final double rawX = (bestC + 0.5) / _cols;
    final double rawY = _scanTop +
        (bestR + 0.5) / _rows * (_scanBottom - _scanTop);

    if (detected) {
      // Check if this candidate is consistent with our lock position
      final double distFromLock = _hypot(rawX - _lockedX, rawY - _lockedY);

      if (_locked && distFromLock > _unlockDist) {
        // Candidate jumped far from lock — probably noise. Ignore.
        // Keep existing locked position.
        hasLock = true;
        return;
      }

      // Accumulate consistent frames
      _consistentFrames =
          (_consistentFrames + 1).clamp(0, _lockFrames + 1);

      if (_consistentFrames >= _lockFrames && !_locked) {
        _locked  = true;
        _lockedX = slotNormX;
        _lockedY = slotNormY;
      }

      // Apply appropriate alpha
      final double alpha = _locked ? _lockedAlpha : _seekAlpha;
      slotNormX += (rawX - slotNormX) * alpha;
      slotNormY += (rawY - slotNormY) * alpha;

      // Keep lock reference updated (very slowly)
      if (_locked) {
        _lockedX += (rawX - _lockedX) * 0.01;
        _lockedY += (rawY - _lockedY) * 0.01;
      }

      hasLock = true;
    } else {
      _consistentFrames = (_consistentFrames - 1).clamp(0, _lockFrames);
      if (_consistentFrames == 0) {
        _locked = false;
        hasLock = false;
      }
      // Position stays at last known value
    }
  }

  double _hypot(double dx, double dy) => sqrt(dx * dx + dy * dy);

  void reset() {
    slotNormX        = 0.50;
    slotNormY        = 0.28;
    hasLock          = false;
    _locked          = false;
    _lockedX         = 0.50;
    _lockedY         = 0.28;
    _consistentFrames = 0;
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

        // ── Dotted trajectory arc ─────────────────────────────────────────
        // Redraws every dot-animation frame with the latest target position
        // from the slot tracker — so the arc follows the bin hole in real time.
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (context, _) => CustomPaint(
            size: size,
            painter: _TrajectoryPainter(
              launch:         Offset(launchX, launchY),
              target:         Offset(targetX, targetY),
              animationValue: _dotCtrl.value,
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
// _TrajectoryPainter
//
// Draws the Angry Birds-style dotted arc from launch (bottom-center) to the
// slot position tracked by _SlotTracker.
//
// DOT DETAILS:
//   • 28 dots on a quadratic Bézier curve
//   • Dots larger near launch, smaller near target (perspective)
//   • Phase offset makes dots march toward target continuously
//   • Color: red when idle, orange when detecting (flap open)
//   • Dots pulse brighter when hasLock = true (slot found)
//
// TARGET RETICLE:
//   • Crosshair drawn at exact tracked slot position
//   • Ring grows and pulses when bottle is actively being detected
//   • Reticle dims when hasLock = false (slot not found in frame)
// ══════════════════════════════════════════════════════════════════════════════
class _TrajectoryPainter extends CustomPainter {
  const _TrajectoryPainter({
    required this.launch,
    required this.target,
    required this.animationValue,
    required this.isDetecting,
    required this.hasLock,
  });

  final Offset launch;
  final Offset target;
  final double animationValue;
  final bool   isDetecting;
  final bool   hasLock;       // true = slot tracker has found the bin hole

  static const int   _dotCount = 28;
  static const Color _idleColor   = Color(0xFFE53935);
  static const Color _detectColor = Color(0xFFFF6B35);
  static const Color _dimColor    = Color(0xFFE53935);

  @override
  void paint(Canvas canvas, Size size) {
    // ── Bézier control point (peak of arc) ───────────────────────────────────
    final Offset mid = Offset(
      (launch.dx + target.dx) / 2,
      (launch.dy + target.dy) / 2,
    );
    final double arcHeight =
        (launch.dy - target.dy).abs() * 0.65 + 80;
    final Offset ctrl = Offset(mid.dx, mid.dy - arcHeight);

    // Quadratic Bézier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
    Offset bezier(double t) {
      final double mt = 1.0 - t;
      return Offset(
        mt * mt * launch.dx + 2 * mt * t * ctrl.dx + t * t * target.dx,
        mt * mt * launch.dy + 2 * mt * t * ctrl.dy + t * t * target.dy,
      );
    }

    // Opacity multiplier: dimmed when slot not found
    final double lockOpacity = hasLock ? 1.0 : 0.40;

    // ── Draw dots ────────────────────────────────────────────────────────────
    for (int i = 0; i < _dotCount; i++) {
      final double t = (i / _dotCount + animationValue) % 1.0;
      final Offset pos = bezier(t);

      // Size: 9px at launch → 3.5px at target
      final double dotR = _lerp(9.0, 3.5, t) / 2;

      // Fade at the very ends
      final double edgeOp = t < 0.08
          ? t / 0.08
          : t > 0.90
              ? (1.0 - t) / 0.10
              : 1.0;

      final Color baseColor = isDetecting ? _detectColor : _idleColor;
      canvas.drawCircle(
        pos,
        dotR,
        Paint()
          ..color = baseColor.withOpacity(
              edgeOp.clamp(0.0, 1.0) * lockOpacity * 0.90),
      );
    }

    // ── Target reticle ───────────────────────────────────────────────────────
    _drawReticle(canvas, target, lockOpacity);
  }

  void _drawReticle(Canvas canvas, Offset c, double lockOpacity) {
    final double pulse = isDetecting
        ? 0.5 + sin(animationValue * pi * 4) * 0.5
        : 0.0;

    final Color color = isDetecting ? _detectColor : _idleColor;
    final double ringR = 18.0 + pulse * 8;

    // Outer glow when locked
    if (hasLock) {
      canvas.drawCircle(
        c, ringR + 8,
        Paint()
          ..color = color.withOpacity(0.15 * lockOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6,
      );
    }

    // Main outer ring — thicker when locked
    canvas.drawCircle(
      c, ringR,
      Paint()
        ..color = color.withOpacity((0.85 + pulse * 0.15) * lockOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hasLock ? 3.0 : 1.8,
    );

    // Inner ring only when locked
    if (hasLock) {
      canvas.drawCircle(
        c, ringR * 0.50,
        Paint()
          ..color = color.withOpacity(0.50 * lockOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Centre dot — bigger when locked
    canvas.drawCircle(
      c, hasLock ? 5.5 : 3.5,
      Paint()..color = color.withOpacity(0.95 * lockOpacity),
    );

    // Crosshair arms — longer when locked
    final double arm = hasLock ? 16.0 : 10.0;
    const double gap = 7;
    final Paint lp = Paint()
      ..color = color.withOpacity(0.85 * lockOpacity)
      ..strokeWidth = hasLock ? 2.2 : 1.6
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(c.dx, c.dy - gap),
        Offset(c.dx, c.dy - gap - arm), lp);
    canvas.drawLine(Offset(c.dx, c.dy + gap),
        Offset(c.dx, c.dy + gap + arm), lp);
    canvas.drawLine(Offset(c.dx - gap, c.dy),
        Offset(c.dx - gap - arm, c.dy), lp);
    canvas.drawLine(Offset(c.dx + gap, c.dy),
        Offset(c.dx + gap + arm, c.dy), lp);

    // "LOCKED" label below reticle
    if (hasLock && !isDetecting) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'SLOT LOCKED',
          style: TextStyle(
            color: color.withOpacity(0.75),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(c.dx - tp.width / 2, c.dy + ringR + 10));
    }
  }

  @override
  bool shouldRepaint(_TrajectoryPainter old) =>
      old.launch         != launch         ||
      old.target         != target         ||
      old.animationValue != animationValue ||
      old.isDetecting    != isDetecting    ||
      old.hasLock        != hasLock;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;