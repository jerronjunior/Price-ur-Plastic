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

  // ── Arrow color based on state ──────────────────────────────────────────────
  Color get _arrowColor {
    if (_calibrating) return Colors.white38;
    if (_engine.lastRejectedByShake) return Colors.redAccent;
    if (_engine.state == _FlapState.open) return Colors.orangeAccent;
    if (!_engine.isCalibrated) return Colors.white38;
    return const Color(0xFF58D68D);
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

          // ── 3D AR Arrow ────────────────────────────────────────────────
          // Renders a 3D perspective arrow (like the reference image) floating
          // over the camera feed. Points downward to show bottle insertion
          // direction. Bobs gently up and down. Changes color on detection.
          Positioned.fill(
            child: _Ar3DArrow(
              bounceCtrl: _flowCtrl,
              color: _arrowColor,
              isDetecting: _engine.state == _FlapState.open,
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
    if (_engine.state == _FlapState.open) return 'Detecting…';
    return 'Insert bottle into slot';
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
        // Ease in-out bob: 0→18px down then back up
        final double t = Curves.easeInOut.transform(bounceCtrl.value);
        final double bob = t * 18.0;

        return Center(
          child: Transform.translate(
            offset: Offset(0, bob),
            child: CustomPaint(
              size: const Size(140, 220),
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

  // Derive shading colors from the main color
  Color get _dark    => Color.lerp(color, Colors.black, 0.45)!;
  Color get _darker  => Color.lerp(color, Colors.black, 0.65)!;
  Color get _light   => Color.lerp(color, Colors.white, 0.50)!;
  Color get _shadow  => Colors.black.withOpacity(0.45);

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;

    // ── Arrow body path (cubic Bézier, curves left then down) ───────────────
    // Start point: upper-center
    // Control points: lean slightly right at top, then curve to center-bottom
    // End point: lower-center (arrowhead tip area)
    final double bodyStrokeW = w * 0.22; // tube thickness
    final double headH = h * 0.30;       // height of arrowhead
    final double bodyEndY = h - headH;   // where the body ends

    // The curve control points give the organic arc from the reference image
    final Offset p0 = Offset(w * 0.52, 0);
    final Offset c1 = Offset(w * 0.70, h * 0.25);
    final Offset c2 = Offset(w * 0.55, h * 0.50);
    final Offset p1 = Offset(w * 0.50, bodyEndY);

    final Path bodyPath = Path()
      ..moveTo(p0.dx, p0.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p1.dx, p1.dy);

    // ── Layer 1: Drop shadow ─────────────────────────────────────────────────
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = _shadow
        ..style = PaintingStyle.stroke
        ..strokeWidth = bodyStrokeW + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // ── Layer 2: Dark edge (bottom face of the 3D tube) ──────────────────────
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = _darker
        ..style = PaintingStyle.stroke
        ..strokeWidth = bodyStrokeW + 6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // ── Layer 3: Main fill ───────────────────────────────────────────────────
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = bodyStrokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // ── Layer 4: Highlight streak (top face of tube — simulates light) ───────
    // Slightly offset upward-left from the main path to look like a lit edge
    final Path highlightPath = Path()
      ..moveTo(p0.dx - 6, p0.dy + 4)
      ..cubicTo(c1.dx - 6, c1.dy + 4, c2.dx - 6, c2.dy + 4, p1.dx - 4, p1.dy);

    canvas.drawPath(
      highlightPath,
      Paint()
        ..color = _light.withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = bodyStrokeW * 0.35
        ..strokeCap = StrokeCap.round,
    );

    // ── Arrowhead (3D cone, pointing downward) ───────────────────────────────
    // The head is built from two faces:
    //   Face A (front face, main color): wide triangle pointing down
    //   Face B (bottom plane, darker):   narrower shape offset down-right
    //
    // tip of arrowhead
    final double tipX = w * 0.50;
    final double tipY = h;
    // left and right shoulders of the head
    final double shoulderY = bodyEndY + h * 0.04;
    final double headHalfW = w * 0.46;
    final double leftX  = tipX - headHalfW;
    final double rightX = tipX + headHalfW;

    // Face B — bottom/shadow plane of the 3D cone (drawn first, behind face A)
    final double depthOffset = h * 0.055; // how deep the bottom face sits
    final Path faceB = Path()
      ..moveTo(leftX + depthOffset,  shoulderY + depthOffset)
      ..lineTo(rightX + depthOffset, shoulderY + depthOffset)
      ..lineTo(tipX  + depthOffset,  tipY + depthOffset * 0.6)
      ..close();

    canvas.drawPath(faceB, Paint()..color = _darker);

    // Drop shadow for the head
    canvas.drawPath(
      faceB,
      Paint()
        ..color = _shadow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Face A — front face of the 3D cone (main color)
    final Path faceA = Path()
      ..moveTo(leftX,  shoulderY)
      ..lineTo(rightX, shoulderY)
      ..lineTo(tipX,   tipY)
      ..close();

    canvas.drawPath(faceA, Paint()..color = color);

    // Highlight on left edge of the arrowhead (lit corner)
    final Path headHighlight = Path()
      ..moveTo(leftX,  shoulderY)
      ..lineTo(tipX,   tipY)
      ..lineTo(tipX - headHalfW * 0.3, tipY - h * 0.04)
      ..close();

    canvas.drawPath(
      headHighlight,
      Paint()..color = _light.withOpacity(0.35),
    );

    // Dark right edge of the arrowhead (shadow side)
    final Path headShadow = Path()
      ..moveTo(rightX, shoulderY)
      ..lineTo(tipX,   tipY)
      ..lineTo(tipX + headHalfW * 0.3, tipY - h * 0.04)
      ..close();

    canvas.drawPath(
      headShadow,
      Paint()..color = _dark.withOpacity(0.5),
    );

    // Glow ring when actively detecting
    if (isDetecting) {
      canvas.drawPath(
        bodyPath,
        Paint()
          ..color = color.withOpacity(0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = bodyStrokeW + 20
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
      );
    }
  }

  @override
  bool shouldRepaint(_Ar3DArrowPainter old) =>
      old.color != color || old.isDetecting != isDetecting;
}