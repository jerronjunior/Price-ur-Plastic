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

    // Flowing arrows: 1200ms per full cycle, repeating
    _flowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

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

          // ── OUTSIDE → INSIDE animated arrow ───────────────────────────
          // 3 chevrons flow downward sequentially showing insertion direction.
          // Positioned in the center of the screen over the bin slot.
          // Each chevron fades in and out in turn: top → mid → bottom,
          // creating a "flowing into slot" motion cue.
          Positioned.fill(
            child: _FlowingArrow(
              flowCtrl: _flowCtrl,
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
// Flowing Arrow Widget
//
// Shows 3 chevron arrows stacked vertically in the CENTER of the screen.
// They animate sequentially top → middle → bottom, each fading in then out,
// creating the visual illusion of motion flowing FROM OUTSIDE INTO THE SLOT.
//
// Layout (screen center):
//
//     ∨   ← chevron 1 (appears first)
//     ∨   ← chevron 2 (appears second)
//     ∨   ← chevron 3 (appears last — closest to slot)
//   ─────   ← slot line (static, shows where the slot is)
//
// Color changes:
//   green  = idle, ready
//   orange = flap is open (bottle going in right now)
//   red    = shake detected
//   grey   = calibrating
// ══════════════════════════════════════════════════════════════════════════════
class _FlowingArrow extends StatelessWidget {
  const _FlowingArrow({
    required this.flowCtrl,
    required this.color,
    required this.isDetecting,
  });

  final AnimationController flowCtrl;
  final Color color;
  final bool isDetecting;

  // Each chevron occupies a phase window within the 0..1 animation cycle.
  // phase=0.0 → top chevron starts first
  // phase=0.33 → middle chevron starts 400ms later
  // phase=0.66 → bottom chevron starts 800ms later
  double _chevronOpacity(double animValue, double phase) {
    // Each chevron is fully visible for 0.35 of the cycle, then fades
    final double t = (animValue - phase + 1.0) % 1.0;
    if (t < 0.18) return t / 0.18;         // fade in
    if (t < 0.35) return 1.0;              // hold
    if (t < 0.50) return 1.0 - (t - 0.35) / 0.15; // fade out
    return 0.0;                            // off
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: flowCtrl,
      builder: (context, _) {
        final double v = flowCtrl.value;
        final double op1 = _chevronOpacity(v, 0.00);
        final double op2 = _chevronOpacity(v, 0.33);
        final double op3 = _chevronOpacity(v, 0.66);

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top chevron — first to appear
              Opacity(
                opacity: op1.clamp(0.0, 1.0),
                child: _Chevron(color: color, size: 48),
              ),
              const SizedBox(height: 6),

              // Middle chevron — second
              Opacity(
                opacity: op2.clamp(0.0, 1.0),
                child: _Chevron(color: color, size: 56),
              ),
              const SizedBox(height: 6),

              // Bottom chevron — last, closest to slot — slightly larger
              Opacity(
                opacity: op3.clamp(0.0, 1.0),
                child: _Chevron(color: color, size: 64),
              ),

              const SizedBox(height: 14),

              // Slot entry line — shows where the bottle enters
              // Glows brighter when detecting
              Container(
                width: 120,
                height: 5,
                decoration: BoxDecoration(
                  color: color.withOpacity(isDetecting ? 1.0 : 0.55),
                  borderRadius: BorderRadius.circular(99),
                  boxShadow: isDetecting
                      ? [BoxShadow(color: color.withOpacity(0.6), blurRadius: 12, spreadRadius: 2)]
                      : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Single chevron "V" shape — drawn as a thick angled stroke
class _Chevron extends StatelessWidget {
  const _Chevron({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * 0.55),
      painter: _ChevronPainter(color: color),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.55
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Draw a V-shape (chevron pointing downward)
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0);

    // Subtle glow layer
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.height * 0.9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}