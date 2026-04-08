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
class _SlotTracker {
  // Grid dimensions
  static const int _cols = 9;
  static const int _rows = 6;

  // Only scan the upper portion of frame (slot is never at the very bottom)
  static const double _scanTopFrac    = 0.00;
  static const double _scanBottomFrac = 0.72;

  // Minimum brightness for a cell to be considered as the slot
  // (below this = too dark, phone not aimed at bin)
  static const double _minSlotBrightness = 80.0;

  // Low-pass filter coefficient (0 = never moves, 1 = instant snap)
  static const double _alpha = 0.12;

  // Exposed tracked position in normalized screen coords (0–1)
  double slotNormX = 0.50;
  double slotNormY = 0.30;

  // Whether the tracker currently has a confident lock on the slot
  bool hasLock = false;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;

    final int scanY0 = (_scanTopFrac    * fh).toInt();
    final int scanY1 = (_scanBottomFrac * fh).toInt();

    final int cellW = (fw / _cols).toInt().clamp(1, fw);
    final int cellH = ((scanY1 - scanY0) / _rows).toInt().clamp(1, fh);

    double bestBrightness = 0;
    int bestCol = _cols ~/ 2;
    int bestRow = _rows ~/ 2;

    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        final int x0 = col * cellW;
        final int y0 = scanY0 + row * cellH;
        final int x1 = (x0 + cellW).clamp(0, fw);
        final int y1 = (y0 + cellH).clamp(0, fh);

        double sum = 0;
        int count = 0;
        // Sample every 6th pixel for speed
        for (int py = y0; py < y1; py += 6) {
          for (int px = x0; px < x1; px += 6) {
            final int idx = py * fw + px;
            if (idx < yPlane.length) {
              sum += yPlane[idx];
              count++;
            }
          }
        }
        final double brightness = count > 0 ? sum / count : 0;

        if (brightness > bestBrightness) {
          bestBrightness = brightness;
          bestCol = col;
          bestRow = row;
        }
      }
    }

    hasLock = bestBrightness >= _minSlotBrightness;

    if (hasLock) {
      // Centre of the winning cell in normalised coords
      final double rawX = (bestCol + 0.5) / _cols;
      final double rawY = _scanTopFrac +
          (bestRow + 0.5) / _rows * (_scanBottomFrac - _scanTopFrac);

      // Low-pass smooth
      slotNormX += (rawX - slotNormX) * _alpha;
      slotNormY += (rawY - slotNormY) * _alpha;
    }
    // else: keep last known position
  }

  void reset() {
    slotNormX = 0.50;
    slotNormY = 0.30;
    hasLock = false;
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
    if (_calibrating)                  return 'Calibrating…';
    if (_engine.lastRejectedByShake)   return 'Hold camera steady';
    if (!_engine.isCalibrated)         return 'Getting ready…';
    if (!_tracker.hasLock)             return 'Point camera at the bin slot';
    if (_engine.state == _FlapState.open) return 'Detecting…';
    return 'Aim arc at slot — insert bottle';
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

    // Outer ring
    canvas.drawCircle(
      c, ringR,
      Paint()
        ..color = color.withOpacity((0.75 + pulse * 0.25) * lockOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Second inner ring when locked
    if (hasLock) {
      canvas.drawCircle(
        c, ringR * 0.55,
        Paint()
          ..color = color.withOpacity(0.35 * lockOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // Centre dot
    canvas.drawCircle(
      c, 4.5,
      Paint()..color = color.withOpacity(0.95 * lockOpacity),
    );

    // Crosshair arms
    const double arm = 12;
    const double gap =  7;
    final Paint lp = Paint()
      ..color = color.withOpacity(0.80 * lockOpacity)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
        Offset(c.dx,       c.dy - gap),
        Offset(c.dx,       c.dy - gap - arm), lp);
    canvas.drawLine(
        Offset(c.dx,       c.dy + gap),
        Offset(c.dx,       c.dy + gap + arm), lp);
    canvas.drawLine(
        Offset(c.dx - gap, c.dy),
        Offset(c.dx - gap - arm, c.dy), lp);
    canvas.drawLine(
        Offset(c.dx + gap, c.dy),
        Offset(c.dx + gap + arm, c.dy), lp);
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