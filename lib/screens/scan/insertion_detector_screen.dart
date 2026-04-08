import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ══════════════════════════════════════════════════════════════════════════════
// pubspec.yaml — add this dependency:
//   sensors_plus: ^4.0.2
// ══════════════════════════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════════════════════════
// Flap Detection Engine
// ══════════════════════════════════════════════════════════════════════════════
enum _FlapState { idle, open }

class _FlapEngine {
  Rect zone = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);
  Rect referenceZone = const Rect.fromLTRB(0.78, 0.20, 0.96, 0.55);

  double baselineBrightness = 0;
  double baselineReferenceBrightness = 0;
  bool isCalibrated = false;
  double darkThresholdFraction = 0.25;

  static const double _shakeRejectFraction = 0.12;

  _FlapState state = _FlapState.idle;
  double currentBrightness = 0;
  double currentReferenceBrightness = 0;
  bool lastRejectedByShake = false;
  DateTime? _flapOpenTime;

  static const int _minFlapOpenMs = 150;
  static const int _maxFlapOpenMs = 3000;
  static const int _cooldownMs = 2500;
  DateTime? _lastCount;

  bool get inCooldown {
    if (_lastCount == null) return false;
    return DateTime.now().difference(_lastCount!).inMilliseconds < _cooldownMs;
  }

  double get darkThreshold => baselineBrightness * (1.0 - darkThresholdFraction);

  bool processFrame(CameraImage image) {
    if (!isCalibrated || inCooldown) return false;

    currentBrightness = _zoneBrightness(image, zone);
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
            DateTime.now().difference(_flapOpenTime!).inMilliseconds >
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
      baselineBrightness = b;
      baselineReferenceBrightness = r;
    } else {
      baselineBrightness = baselineBrightness * 0.7 + b * 0.3;
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
    final int x0 = (z.left * fw).toInt().clamp(0, fw - 1);
    final int y0 = (z.top * fh).toInt().clamp(0, fh - 1);
    final int x1 = (z.right * fw).toInt().clamp(0, fw - 1);
    final int y1 = (z.bottom * fh).toInt().clamp(0, fh - 1);
    double sum = 0;
    int count = 0;
    const int step = 4;
    for (int py = y0; py < y1; py += step) {
      for (int px = x0; px < x1; px += step) {
        final int idx = py * fw + px;
        if (idx < yPlane.length) {
          sum += yPlane[idx];
          count++;
        }
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
// Insertion Detector Screen
// ══════════════════════════════════════════════════════════════════════════════
class InsertionDetectorScreen extends StatefulWidget {
  const InsertionDetectorScreen({
    super.key,
    required this.onDetected,
    required this.onBack,
    this.onTimeout,
    this.timeoutSeconds = 20,
  });

  final VoidCallback onDetected;
  final VoidCallback onBack;
  final VoidCallback? onTimeout;
  final int timeoutSeconds;

  @override
  State<InsertionDetectorScreen> createState() =>
      _InsertionDetectorScreenState();
}

class _InsertionDetectorScreenState extends State<InsertionDetectorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _detected = false;

  // ── Engine ─────────────────────────────────────────────────────────────────
  final _FlapEngine _engine = _FlapEngine();

  // ── Calibration ────────────────────────────────────────────────────────────
  bool _calibrating = false;
  int _calibrationFrames = 0;
  static const int _calibrationFrameCount = 25;

  // ── Timeout ────────────────────────────────────────────────────────────────
  Timer? _timeoutTimer;
  late int _remainingSeconds;

  // ── Dot animation (marching ants — dots travel along the arc) ──────────────
  late AnimationController _dotCtrl;

  // ── Flash on count ─────────────────────────────────────────────────────────
  late AnimationController _flashCtrl;
  bool _showFlash = false;

  // ── Accelerometer — shifts target point as phone tilts ────────────────────
  // _tiltX: -1.0 (tilted far left) → +1.0 (tilted far right)
  // _tiltY: -1.0 (tilted far back) → +1.0 (tilted far forward)
  double _tiltX = 0.0;
  double _tiltY = 0.0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // Smoothed tilt (low-pass filter to avoid jitter)
  double _smoothTiltX = 0.0;
  double _smoothTiltY = 0.0;
  static const double _tiltSmooth = 0.08; // lower = smoother but slower

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    // Dots march along the arc, full cycle 1000ms
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _startAccelerometer();
    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _accelSub?.cancel();
    _dotCtrl.dispose();
    _flashCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) _cam?.dispose();
    if (state == AppLifecycleState.resumed) _initCamera();
  }

  // ── Accelerometer ───────────────────────────────────────────────────────────
  void _startAccelerometer() {
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent e) {
      if (!mounted) return;
      // Accelerometer X: tilting right → negative X gravity → target moves right
      // Clamp raw value to ±5 m/s², normalise to ±1
      final double rawX = (-e.x / 5.0).clamp(-1.0, 1.0);
      // Accelerometer Y: tilting forward → positive Y → target moves up (lower Y on screen)
      final double rawY = ((e.y - 9.0) / 4.0).clamp(-1.0, 1.0);

      // Low-pass smooth
      _smoothTiltX += (_tiltX - _smoothTiltX) * _tiltSmooth +
          (rawX - _tiltX) * _tiltSmooth;
      _smoothTiltY += (_tiltY - _smoothTiltY) * _tiltSmooth +
          (rawY - _tiltY) * _tiltSmooth;
      _tiltX = rawX;
      _tiltY = rawY;

      // Rebuild only the trajectory — lightweight setState
      if (mounted) setState(() {});
    });
  }

  // ── Timeout ─────────────────────────────────────────────────────────────────
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

  // ── Camera ──────────────────────────────────────────────────────────────────
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
        _cameraReady = true;
        _calibrating = true;
        _calibrationFrames = 0;
        _engine.baselineBrightness = 0;
        _engine.baselineReferenceBrightness = 0;
        _engine.isCalibrated = false;
        _engine.reset();
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
      if (_calibrating) {
        _engine.addCalibrationSample(image);
        _calibrationFrames++;
        if (_calibrationFrames >= _calibrationFrameCount) {
          _engine.finalizeCalibration();
          if (mounted) setState(() { _calibrating = false; _calibrationFrames = 0; });
        }
        return;
      }

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

  // ── Status text ──────────────────────────────────────────────────────────────
  String get _statusText {
    if (_calibrating) return 'Calibrating…';
    if (_engine.lastRejectedByShake) return 'Hold camera steady';
    if (!_engine.isCalibrated) return 'Getting ready…';
    if (_engine.state == _FlapState.open) return 'Detecting…';
    return 'Aim at slot and insert bottle';
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
          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w500),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF67E8A8)));
    }

    return LayoutBuilder(builder: (ctx, box) {
      final Size size = Size(box.maxWidth, box.maxHeight);

      // ── Target point: bin slot is roughly upper-center of the camera view ──
      // Base position: 50% across, 30% down from top
      // Tilt shifts it: ±20% horizontal, ±10% vertical
      final double targetX = size.width  * (0.50 + _smoothTiltX * 0.20);
      final double targetY = size.height * (0.30 + _smoothTiltY * 0.10);

      // Launch point: bottom-center (where bottle is held)
      final double launchX = size.width * 0.50;
      final double launchY = size.height * 0.92;

      return Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview ──────────────────────────────────────────────
          ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: size.width,
                  height: size.width / _cam!.value.aspectRatio,
                  child: CameraPreview(_cam!),
                ),
              ),
            ),
          ),

          // ── Very subtle dark overlay so dots are visible ─────────────────
          Container(color: Colors.black.withValues(alpha: 0.10)),

          // ── Count flash ──────────────────────────────────────────────────
          if (_showFlash)
            AnimatedBuilder(
              animation: _flashCtrl,
              builder: (_, __) => Opacity(
                opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
                child: Container(color: Colors.white.withValues(alpha: 0.35)),
              ),
            ),

          // ── Angry Birds dotted trajectory arc ───────────────────────────
          // Full screen painter — draws the arc from launch → target
          AnimatedBuilder(
            animation: _dotCtrl,
            builder: (context, _) => CustomPaint(
              size: size,
              painter: _TrajectoryPainter(
                launch: Offset(launchX, launchY),
                target: Offset(targetX, targetY),
                animationValue: _dotCtrl.value,
                isDetecting: _engine.state == _FlapState.open,
                isCalibrated: _engine.isCalibrated,
              ),
            ),
          ),

          // ── Countdown ────────────────────────────────────────────────────
          Positioned(
            top: 18,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 86,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.52),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  '$_remainingSeconds',
                  style: TextStyle(
                    color: _remainingSeconds <= 5 ? Colors.redAccent : Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),

          // ── Calibration bar ──────────────────────────────────────────────
          if (_calibrating)
            Positioned(
              top: 108, left: 32, right: 32,
              child: Column(children: [
                const Text('Calibrating — keep slot clear',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center),
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

          // ── Shake warning ────────────────────────────────────────────────
          if (_engine.lastRejectedByShake)
            Positioned(
              top: 108, left: 0, right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.warning_amber, color: Colors.white, size: 14),
                    SizedBox(width: 6),
                    Text('Camera moved — hold steady',
                        style: TextStyle(color: Colors.white, fontSize: 12)),
                  ]),
                ),
              ),
            ),

          // ── Status label ─────────────────────────────────────────────────
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'Tilt phone to aim the arc at the slot. Insert bottle.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.3),
              ),
            ),
          ),
        ],
      );
    });
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _TrajectoryPainter
//
// Draws the Angry Birds-style dotted arc trajectory from the launch point
// (bottom of screen, where the bottle is) to the target point (bin slot,
// which shifts with phone tilt).
//
// HOW THE ARC IS COMPUTED:
//   Uses a quadratic Bézier curve:
//     - P0 = launch point (bottom-center)
//     - P1 = control point (peak of the arc, above midpoint between P0 and P2)
//     - P2 = target point (bin slot, upper area)
//
//   The control point height is calculated so the arc peaks about 60% above
//   the midpoint between launch and target — giving the natural ballistic curve.
//
// DOT SPACING AND SIZING:
//   ~30 dots are placed at equal parameter intervals along the Bézier.
//   Dots near the launch are larger (bottle just left your hand).
//   Dots near the target are smaller (perspective depth, further away).
//   The "marching ants" animation shifts the phase offset each frame so dots
//   appear to travel continuously from launch toward target.
//
// TARGET RETICLE:
//   A small crosshair circle drawn at the target point shows exactly where
//   the arc lands. It pulses when the flap is open (bottle detected).
// ══════════════════════════════════════════════════════════════════════════════
class _TrajectoryPainter extends CustomPainter {
  const _TrajectoryPainter({
    required this.launch,
    required this.target,
    required this.animationValue,
    required this.isDetecting,
    required this.isCalibrated,
  });

  final Offset launch;
  final Offset target;
  final double animationValue; // 0.0 → 1.0, drives marching animation
  final bool isDetecting;
  final bool isCalibrated;

  static const int _dotCount = 28;
  static const Color _dotColor = Color(0xFFE53935); // vivid red

  @override
  void paint(Canvas canvas, Size size) {
    // ── Bézier control point (arc peak) ──────────────────────────────────────
    final Offset mid = Offset(
      (launch.dx + target.dx) / 2,
      (launch.dy + target.dy) / 2,
    );

    // Arc peak: high above the midpoint
    // The higher above, the more pronounced the arc
    final double arcHeight = (launch.dy - target.dy).abs() * 0.65 + 80;
    final Offset ctrl = Offset(mid.dx, mid.dy - arcHeight);

    // ── Evaluate quadratic Bézier at parameter t ──────────────────────────────
    // B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
    Offset bezier(double t) {
      final double mt = 1.0 - t;
      return Offset(
        mt * mt * launch.dx + 2 * mt * t * ctrl.dx + t * t * target.dx,
        mt * mt * launch.dy + 2 * mt * t * ctrl.dy + t * t * target.dy,
      );
    }

    // ── Draw dots ─────────────────────────────────────────────────────────────
    // Phase offset makes dots appear to march from launch → target
    final double phase = animationValue;

    for (int i = 0; i < _dotCount; i++) {
      // t: parameter along arc (0 = launch, 1 = target)
      // Add phase offset so dots march; modulo keeps them on arc
      double t = (i / _dotCount + phase) % 1.0;

      final Offset pos = bezier(t);

      // Size: larger near launch (t≈0), smaller near target (t≈1)
      // Range: 9px → 3.5px
      final double dotSize = lerpDouble(9.0, 3.5, t)!;

      // Opacity: fully opaque in middle, slightly faded at edges
      final double opacity = t < 0.08
          ? (t / 0.08).clamp(0.0, 1.0)
          : t > 0.90
              ? ((1.0 - t) / 0.10).clamp(0.0, 1.0)
              : 1.0;

      // Color: brighter red when detecting
      final Color color = isDetecting
          ? const Color(0xFFFF6B35).withOpacity(opacity * 0.92)
          : _dotColor.withOpacity(opacity * 0.85);

      canvas.drawCircle(pos, dotSize / 2, Paint()..color = color);
    }

    // ── Target reticle — crosshair at the bin slot ────────────────────────────
    _drawReticle(canvas, target);
  }

  void _drawReticle(Canvas canvas, Offset center) {
    final double pulse = isDetecting ? 0.5 + sin(animationValue * pi * 4) * 0.5 : 0.0;
    final double ringR = 16.0 + pulse * 6;

    // Outer ring
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..color = _dotColor.withOpacity(0.75 + pulse * 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Inner dot
    canvas.drawCircle(
      center,
      4.0,
      Paint()..color = _dotColor.withOpacity(0.9),
    );

    // Four short crosshair lines
    const double armLen = 10;
    const double gap    = 6;
    final Paint linePaint = Paint()
      ..color = _dotColor.withOpacity(0.80)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(center.dx, center.dy - gap),
        Offset(center.dx, center.dy - gap - armLen), linePaint);
    canvas.drawLine(Offset(center.dx, center.dy + gap),
        Offset(center.dx, center.dy + gap + armLen), linePaint);
    canvas.drawLine(Offset(center.dx - gap, center.dy),
        Offset(center.dx - gap - armLen, center.dy), linePaint);
    canvas.drawLine(Offset(center.dx + gap, center.dy),
        Offset(center.dx + gap + armLen, center.dy), linePaint);
  }

  @override
  bool shouldRepaint(_TrajectoryPainter old) =>
      old.launch != launch ||
      old.target != target ||
      old.animationValue != animationValue ||
      old.isDetecting != isDetecting;
}

// Dart doesn't expose lerpDouble at top level without ui import — inline it:
double? lerpDouble(double a, double b, double t) => a + (b - a) * t;