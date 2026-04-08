import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Flap Detection Engine (unchanged from previous version)
// ══════════════════════════════════════════════════════════════════════════════
enum _FlapState { idle, open }

class _FlapEngine {
  Rect zone = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);
  Rect referenceZone = const Rect.fromLTRB(0.78, 0.20, 0.96, 0.55);

  // Bottle must pass these zones (top -> bottom) before count is accepted.
  final List<Rect> pathZones = const [
    Rect.fromLTRB(0.50, 0.28, 0.64, 0.40),
    Rect.fromLTRB(0.45, 0.42, 0.59, 0.54),
    Rect.fromLTRB(0.39, 0.56, 0.53, 0.69),
  ];

  double baselineBrightness = 0;
  double baselineReferenceBrightness = 0;
  List<double> baselinePathBrightness = [];
  bool isCalibrated = false;
  double darkThresholdFraction = 0.25;
  double pathDarkThresholdFraction = 0.20;

  static const double _shakeRejectFraction = 0.12;
  static const int _pathTimeoutMs = 1300;
  static const int _pathReadyWindowMs = 2000;

  _FlapState state = _FlapState.idle;
  double currentBrightness = 0;
  double currentReferenceBrightness = 0;
  List<double> currentPathBrightness = [];
  int pathProgressStep = 0;
  bool bottleOnExpectedPathStep = false;
  DateTime? _lastPathStepTime;
  DateTime? _pathReadyTime;
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
  double get pathProgressFraction => pathProgressStep / pathZones.length;

  bool get _isPathReady {
    if (_pathReadyTime == null) return false;
    return DateTime.now().difference(_pathReadyTime!).inMilliseconds <=
        _pathReadyWindowMs;
  }

  bool processFrame(CameraImage image) {
    if (!isCalibrated || inCooldown) return false;

    currentBrightness = _zoneBrightness(image, zone);
    currentReferenceBrightness = _zoneBrightness(image, referenceZone);
    currentPathBrightness =
        pathZones.map((z) => _zoneBrightness(image, z)).toList(growable: false);

    final bool flapOpen = currentBrightness < darkThreshold;

    _updatePathProgress();

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
          if (_isPathReady) {
            _lastCount = DateTime.now();
            _clearPathProgress();
            return true;
          }
          _clearPathProgress();
          return false;
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
    final List<double> pb =
        pathZones.map((z) => _zoneBrightness(image, z)).toList(growable: false);

    if (baselinePathBrightness.isEmpty) {
      baselinePathBrightness = List<double>.from(pb);
    } else {
      for (int i = 0; i < baselinePathBrightness.length; i++) {
        baselinePathBrightness[i] = baselinePathBrightness[i] * 0.7 + pb[i] * 0.3;
      }
    }

    if (baselineBrightness == 0) {
      baselineBrightness = b;
      baselineReferenceBrightness = r;
    } else {
      baselineBrightness = baselineBrightness * 0.7 + b * 0.3;
      baselineReferenceBrightness = baselineReferenceBrightness * 0.7 + r * 0.3;
    }
  }

  void finalizeCalibration() {
    final bool pathReady = baselinePathBrightness.length == pathZones.length &&
        baselinePathBrightness.every((v) => v > 10);
    isCalibrated = baselineBrightness > 10 && pathReady;
  }

  void _updatePathProgress() {
    final DateTime now = DateTime.now();
    bottleOnExpectedPathStep = false;

    if (_lastPathStepTime != null &&
        now.difference(_lastPathStepTime!).inMilliseconds > _pathTimeoutMs) {
      _clearPathProgress();
    }

    final int expected = pathProgressStep;
    if (expected < pathZones.length &&
        expected < baselinePathBrightness.length &&
        expected < currentPathBrightness.length) {
      final double threshold =
          baselinePathBrightness[expected] * (1.0 - pathDarkThresholdFraction);
      if (currentPathBrightness[expected] < threshold) {
        bottleOnExpectedPathStep = true;
        pathProgressStep++;
        _lastPathStepTime = now;
        if (pathProgressStep >= pathZones.length) {
          _pathReadyTime = now;
        }
      }
    }
  }

  void _clearPathProgress() {
    pathProgressStep = 0;
    bottleOnExpectedPathStep = false;
    _lastPathStepTime = null;
    _pathReadyTime = null;
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
    _clearPathProgress();
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

  // ── Arrow animation ─────────────────────────────────────────────────────────
  // 3 chevrons animate sequentially top→bottom to show "insert into slot"
  // Each completes one full cycle in 1200ms, offset by 400ms each
  late AnimationController _flowCtrl;

  // Flash animation when bottle is counted
  late AnimationController _flashCtrl;
  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    // 3D AR arrow: gentle up/down bob, 1400ms per cycle
    _flowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // White flash on successful count
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
    _flowCtrl.dispose();
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

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _detected) return;
      setState(() => _remainingSeconds--);
      if (_remainingSeconds <= 0) {
        _timeoutTimer?.cancel();
        if (widget.onTimeout != null) {
          widget.onTimeout!();
        } else {
          widget.onBack();
        }
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
          if (mounted) {
            setState(() {
              _calibrating = false;
              _calibrationFrames = 0;
            });
          }
        }
        return;
      }

      final bool counted = _engine.processFrame(image);
      if (mounted) setState(() {});

      if (counted) {
        _detected = true;
        _timeoutTimer?.cancel();
        // Flash white on count
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

  // ── Arrow color (red base, brightens on detection) ─────────────────────────
  Color get _arrowColor {
    if (_calibrating) return Colors.red.withOpacity(0.4);
    if (_engine.state == _FlapState.open) return const Color(0xFFFF6B35);
    return const Color(0xFFE53935); // vivid red
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
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF67E8A8)),
      );
    }

    return LayoutBuilder(builder: (ctx, box) {
      final Size size = Size(box.maxWidth, box.maxHeight);

      return Stack(
        fit: StackFit.expand,
        children: [
          // ── Camera preview ─────────────────────────────────────────────
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

          // ── Subtle dim ─────────────────────────────────────────────────
          Container(color: Colors.black.withValues(alpha: 0.15)),

          // ── Guided bottle path overlay ─────────────────────────────────
          IgnorePointer(
            child: CustomPaint(
              painter: _BottlePathGuidePainter(
                progress: _engine.pathProgressFraction,
                activeStep: _engine.pathProgressStep,
                bottleOnStep: _engine.bottleOnExpectedPathStep,
                isCalibrating: _calibrating,
              ),
            ),
          ),

          // ── Count flash ────────────────────────────────────────────────
          if (_showFlash)
            AnimatedBuilder(
              animation: _flashCtrl,
              builder: (_, __) => Opacity(
                opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
                child: Container(color: Colors.white.withValues(alpha: 0.35)),
              ),
            ),

          // ── Countdown ──────────────────────────────────────────────────
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
                    color:
                        _remainingSeconds <= 5 ? Colors.redAccent : Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),

          // ── Calibration bar ────────────────────────────────────────────
          if (_calibrating)
            Positioned(
              top: 108,
              left: 32,
              right: 32,
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

          // ── Shake warning ──────────────────────────────────────────────
          if (_engine.lastRejectedByShake)
            Positioned(
              top: 108,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber, color: Colors.white, size: 14),
                      SizedBox(width: 6),
                      Text('Camera moved — hold steady',
                          style:
                              TextStyle(color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          // ── 3D AR Arrow — below timer so countdown is never covered ────
          Positioned(
            top: 160,
            left: 0,
            right: 0,
            height: size.height * 0.24,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.78,
                child: _Ar3DArrow(
                  bounceCtrl: _flowCtrl,
                  color: _arrowColor,
                  isDetecting: _engine.state == _FlapState.open,
                ),
              ),
            ),
          ),

          // ── Status label ───────────────────────────────────────────────
          Positioned(
            // Sits just below the bottom chevron arrow
            top: size.height * 0.65,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _statusText,
                  key: ValueKey(_statusText),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _arrowColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black87, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Bottom instruction ─────────────────────────────────────────
          Positioned(
            left: 24,
            right: 24,
            bottom: 28,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text(
                'Pass the bottle through the slot before countdown ends.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  String get _statusText {
    if (_calibrating) return 'Calibrating…';
    if (_engine.lastRejectedByShake) return 'Hold camera steady';
    if (!_engine.isCalibrated) return 'Getting ready…';
    if (_engine.pathProgressStep > 0 && _engine.pathProgressStep < 3) {
      return 'Follow the path to score';
    }
    if (_engine.state == _FlapState.open) return 'Detecting…';
    return 'Move bottle through the guide path';
  }
}

class _BottlePathGuidePainter extends CustomPainter {
  const _BottlePathGuidePainter({
    required this.progress,
    required this.activeStep,
    required this.bottleOnStep,
    required this.isCalibrating,
  });

  final double progress;
  final int activeStep;
  final bool bottleOnStep;
  final bool isCalibrating;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset p1 = Offset(size.width * 0.57, size.height * 0.32);
    final Offset p2 = Offset(size.width * 0.52, size.height * 0.47);
    final Offset p3 = Offset(size.width * 0.46, size.height * 0.61);

    final Path curve = Path()
      ..moveTo(p1.dx, p1.dy)
      ..quadraticBezierTo(size.width * 0.58, size.height * 0.40, p2.dx, p2.dy)
      ..quadraticBezierTo(size.width * 0.49, size.height * 0.54, p3.dx, p3.dy);

    final Paint base = Paint()
      ..color = Colors.white.withOpacity(0.22)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 6;
    canvas.drawPath(curve, base);

    final PathMetric metric = curve.computeMetrics().first;
    final Path done = metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0));
    final Paint donePaint = Paint()
      ..color = bottleOnStep ? const Color(0xFF6AF7A9) : const Color(0xFFE53935)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 7;
    canvas.drawPath(done, donePaint);

    final List<Offset> checkpoints = [p1, p2, p3];
    for (int i = 0; i < checkpoints.length; i++) {
      final bool doneStep = i < activeStep;
      final bool currentStep = i == activeStep && bottleOnStep;
      canvas.drawCircle(
        checkpoints[i],
        10,
        Paint()
          ..color = doneStep || currentStep
              ? const Color(0xFF6AF7A9).withOpacity(0.85)
              : Colors.white.withOpacity(0.35),
      );
      canvas.drawCircle(
        checkpoints[i],
        5,
        Paint()..color = Colors.black.withOpacity(0.35),
      );
    }

    // Draw a small direction arrow at the path end.
    final Paint tip = Paint()..color = const Color(0xFFE53935).withOpacity(0.85);
    final Path head = Path()
      ..moveTo(p3.dx - 10, p3.dy + 6)
      ..lineTo(p3.dx + 10, p3.dy + 6)
      ..lineTo(p3.dx, p3.dy + 22)
      ..close();
    canvas.drawPath(head, tip);

    if (isCalibrating) {
      final TextPainter tp = TextPainter(
        text: const TextSpan(
          text: 'Guide path calibrating',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width * 0.5 - tp.width / 2, size.height * 0.26));
    }
  }

  @override
  bool shouldRepaint(_BottlePathGuidePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeStep != activeStep ||
        oldDelegate.bottleOnStep != bottleOnStep ||
        oldDelegate.isCalibrating != isCalibrating;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _Ar3DArrow
//
// Renders a 3D perspective down-arrow that floats over the camera preview,
// matching the style from the reference image (thick curved tube with
// highlight, shadow, and a solid 3D arrowhead).
//
// HOW THE 3D EFFECT WORKS:
//   The arrow is drawn in THREE layers on top of each other:
//   1. Drop shadow  — offset dark blur below the arrow (depth)
//   2. Dark edge    — slightly wider stroke in a darker shade (gives thickness)
//   3. Main fill    — the primary color stroke
//   4. Highlight    — a thin bright streak on the top-left edge (light source)
//
//   The arrowhead is drawn as a filled 3D cone shape: a large filled triangle
//   (the face) + a darker parallelogram underneath (the bottom plane of the
//   cone), giving it a faceted look.
//
// SHAPE:
//   The arrow body follows a cubic Bézier curve that bends slightly left then
//   curves down — giving the organic arc from the reference image.
//   The arrowhead sits at the bottom tip of the curve.
// ══════════════════════════════════════════════════════════════════════════════
class _Ar3DArrow extends StatelessWidget {
  const _Ar3DArrow({
    required this.bounceCtrl,
    required this.color,
    required this.isDetecting,
  });

  final AnimationController bounceCtrl;
  final Color color;
  final bool isDetecting;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: bounceCtrl,
      builder: (context, _) {
        final double t = Curves.easeInOut.transform(bounceCtrl.value);
        final double bob = t * 4.0; // compact movement like a small indicator

        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: bob),
            child: CustomPaint(
              // Smaller fixed size
              size: const Size(56, 100),
              painter: _Ar3DArrowPainter(
                color: color,
                isDetecting: isDetecting,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Ar3DArrowPainter extends CustomPainter {
  const _Ar3DArrowPainter({
    required this.color,
    required this.isDetecting,
  });

  final Color color;
  final bool isDetecting;

  Color get _dark   => Color.lerp(color, Colors.black, 0.45)!;
  Color get _darker => Color.lerp(color, Colors.black, 0.65)!;
  Color get _light  => Color.lerp(color, Colors.white, 0.40)!;
  Color get _shadow => Colors.black.withOpacity(0.30);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // ── OUTSIDE → INSIDE arrow path ────────────────────────────────────────
    //
    // The tail (p0) starts well above the canvas — it is hidden by the
    // parent ClipRect, creating the "entering from outside the screen" effect.
    //
    // The body sweeps from top-right down and slightly left, landing in the
    // lower-center with the arrowhead pointing straight down.
    //
    //  [above screen — hidden]
    //       p0 •  ← tail: top-right, far above canvas
    //           ↘
    //        c1 •  ← swings right, entering visible area
    //          ↙
    //       c2 •   ← curves back toward center
    //         ↓
    //       p1 •   ← body end, lower-center
    //         ▼    ← arrowhead

    final double stroke = w * 0.20; // tube thickness — small arrow
    final double headH  = h * 0.28;
    final double bodyEndY = h - headH;

    // p0 is -60% above canvas top → fully hidden by ClipRect
    final Offset p0 = Offset(w * 0.68,  -h * 0.60);
    final Offset c1 = Offset(w * 0.82,   h * 0.15);
    final Offset c2 = Offset(w * 0.58,   h * 0.48);
    final Offset p1 = Offset(w * 0.50,   bodyEndY);

    final Path body = Path()
      ..moveTo(p0.dx, p0.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p1.dx, p1.dy);

    // 1 — soft drop shadow
    canvas.drawPath(body, Paint()
      ..color = _shadow
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));

    // 2 — dark bottom face (3D depth)
    canvas.drawPath(body, Paint()
      ..color = _darker
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke + 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // 3 — main red fill
    canvas.drawPath(body, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // 4 — top-left highlight streak (simulates curved 3D surface)
    final Path hl = Path()
      ..moveTo(p0.dx - 4, p0.dy + 5)
      ..cubicTo(c1.dx - 4, c1.dy + 5, c2.dx - 4, c2.dy + 3, p1.dx - 3, p1.dy);
    canvas.drawPath(hl, Paint()
      ..color = _light.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.30
      ..strokeCap = StrokeCap.round);

    // ── Arrowhead ──────────────────────────────────────────────────────────
    final double tx   = w * 0.50;
    final double ty   = h;
    final double sy   = bodyEndY + h * 0.01;
    final double hw   = w * 0.46; // half-width of head
    final double dep  = h * 0.05; // 3D depth offset

    // Back face (darker, offset)
    canvas.drawPath(
      Path()
        ..moveTo(tx - hw + dep, sy + dep)
        ..lineTo(tx + hw + dep, sy + dep)
        ..lineTo(tx + dep,      ty + dep * 0.4)
        ..close(),
      Paint()..color = _darker);

    // Shadow under head
    canvas.drawPath(
      Path()
        ..moveTo(tx - hw, sy)
        ..lineTo(tx + hw, sy)
        ..lineTo(tx,      ty)
        ..close(),
      Paint()
        ..color = _shadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));

    // Front face (main color)
    canvas.drawPath(
      Path()
        ..moveTo(tx - hw, sy)
        ..lineTo(tx + hw, sy)
        ..lineTo(tx,      ty)
        ..close(),
      Paint()..color = color);

    // Left lit edge
    canvas.drawPath(
      Path()
        ..moveTo(tx - hw, sy)
        ..lineTo(tx,      ty)
        ..lineTo(tx - hw * 0.25, ty - h * 0.035)
        ..close(),
      Paint()..color = _light.withOpacity(0.35));

    // Right shadow edge
    canvas.drawPath(
      Path()
        ..moveTo(tx + hw, sy)
        ..lineTo(tx,      ty)
        ..lineTo(tx + hw * 0.25, ty - h * 0.035)
        ..close(),
      Paint()..color = _dark.withOpacity(0.40));

    // Pulse glow when detecting
    if (isDetecting) {
      canvas.drawPath(body, Paint()
        ..color = color.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 18
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
    }
  }

  @override
  bool shouldRepaint(_Ar3DArrowPainter old) =>
      old.color != color || old.isDetecting != isDetecting;
}