import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// FIXES IN THIS VERSION
//
// BUG 1 — Camera shake triggers false count (ROOT CAUSE)
//   Old: engine watched only ONE zone (flap area). Camera shake shifts the
//   entire image so flap zone brightness changes → counted as bottle.
//   Fix: added a REFERENCE zone on the static bin body beside the flap.
//   A real bottle only darkens the flap zone. Camera shake darkens BOTH zones
//   at the same time. Engine now rejects any frame where the reference zone
//   also changes significantly.
//
// BUG 2 — No minimum open duration
//   Camera shakes are very fast (~50ms). Real bottles take 150–700ms to pass.
//   Added _minFlapOpenMs = 150 — rejects events shorter than 150ms.
//
// NEW — Animated augmented AR arrow overlay
//   Shows a bouncing downward arrow so the user knows which direction to
//   insert the bottle. Arrow fades out when a bottle is being detected.
// ══════════════════════════════════════════════════════════════════════════════

enum _FlapState { idle, open }

class _FlapEngine {
  // ── Detection zone (flap with arrow) ──────────────────────────────────────
  Rect zone = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);

  // ── Reference zone (static bin body — used to reject camera shake) ────────
  // Placed on the bin body to the right of the flap. When camera shakes,
  // this zone changes brightness along with the flap zone → ignored.
  // When a real bottle goes in, only the flap zone darkens → counted.
  Rect referenceZone = const Rect.fromLTRB(0.78, 0.20, 0.96, 0.55);

  // ── Calibration ───────────────────────────────────────────────────────────
  double baselineBrightness = 0;
  double baselineReferenceBrightness = 0; // FIX 1: baseline for reference zone
  bool isCalibrated = false;

  // How much darker than baseline = flap is open (0.25 = 25% drop)
  double darkThresholdFraction = 0.25;

  // FIX 1: Max allowed change in reference zone before rejecting as camera shake.
  // If reference changes by more than this fraction → camera moved → ignore.
  static const double _shakeRejectFraction = 0.12;

  // ── State ──────────────────────────────────────────────────────────────────
  _FlapState state = _FlapState.idle;
  double currentBrightness = 0;
  double currentReferenceBrightness = 0;
  bool lastRejectedByShake = false;  // renamed from lastRejectedBySpoof
  DateTime? _flapOpenTime;

  // FIX 2: Minimum time flap must stay open to count (rejects fast shakes)
  static const int _minFlapOpenMs = 150;
  static const int _maxFlapOpenMs = 3000;
  static const int _cooldownMs = 2500;
  DateTime? _lastCount;

  bool get inCooldown {
    if (_lastCount == null) return false;
    return DateTime.now().difference(_lastCount!).inMilliseconds < _cooldownMs;
  }

  double get darkThreshold => baselineBrightness * (1.0 - darkThresholdFraction);

  // ── Main frame processor ───────────────────────────────────────────────────
  bool processFrame(CameraImage image) {
    if (!isCalibrated || inCooldown) return false;

    currentBrightness = _zoneBrightness(image, zone);
    currentReferenceBrightness = _zoneBrightness(image, referenceZone);

    final bool flapOpen = currentBrightness < darkThreshold;

    // FIX 1: Check reference zone for camera shake.
    // If the reference (bin body) brightness also changed a lot, the camera
    // moved — not a bottle insertion. Reject the frame.
    if (baselineReferenceBrightness > 0) {
      final double refChange = (currentReferenceBrightness - baselineReferenceBrightness).abs()
          / baselineReferenceBrightness;
      if (refChange > _shakeRejectFraction) {
        // Camera shook — reset state and ignore this frame
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

          // FIX 2: Reject events shorter than minimum — these are shakes/bumps
          if (openMs < _minFlapOpenMs) {
            state = _FlapState.idle;
            _flapOpenTime = null;
            return false;
          }

          // Reject events longer than maximum — hand blocking the slot
          if (openMs > _maxFlapOpenMs) {
            state = _FlapState.idle;
            _flapOpenTime = null;
            return false;
          }

          // Duration is valid — real bottle insertion ✅
          state = _FlapState.idle;
          _flapOpenTime = null;
          _lastCount = DateTime.now();
          return true;
        }

        // Still open — check for timeout
        if (_flapOpenTime != null &&
            DateTime.now().difference(_flapOpenTime!).inMilliseconds > _maxFlapOpenMs) {
          state = _FlapState.idle;
          _flapOpenTime = null;
        }
        break;
    }

    return false;
  }

  // ── Calibration ───────────────────────────────────────────────────────────
  void addCalibrationSample(CameraImage image) {
    final double b = _zoneBrightness(image, zone);
    final double r = _zoneBrightness(image, referenceZone); // FIX 1: calibrate reference too

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

  // ── Zone brightness helper (Y-plane sampling) ─────────────────────────────
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

  // ── AR Arrow animation ─────────────────────────────────────────────────────
  // NEW: Animated downward arrow showing bottle insertion direction
  late AnimationController _arrowBounceCtrl;
  late Animation<double> _arrowBounce;
  late AnimationController _arrowFadeCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    // AR arrow — slow gentle bounce up and down
    _arrowBounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _arrowBounce = Tween<double>(begin: 0, end: 14).animate(
      CurvedAnimation(parent: _arrowBounceCtrl, curve: Curves.easeInOut),
    );

    // Arrow fades out when flap opens (bottle detected)
    _arrowFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0,
    );

    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _arrowBounceCtrl.dispose();
    _arrowFadeCtrl.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera error: $e')),
      );
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
          if (mounted) setState(() {
            _calibrating = false;
            _calibrationFrames = 0;
          });
        }
        return;
      }

      final bool counted = _engine.processFrame(image);

      if (mounted) {
        // Fade arrow out when flap is open
        if (_engine.state == _FlapState.open) {
          _arrowFadeCtrl.animateTo(0.0);
        } else {
          _arrowFadeCtrl.animateTo(1.0);
        }
        setState(() {});
      }

      if (counted) {
        _detected = true;
        _timeoutTimer?.cancel();
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted) widget.onDetected();
        });
      }
    } finally {
      _processingFrame = false;
    }
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
      body: _buildCamera(),
    );
  }

  Widget _buildCamera() {
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
          // ── Camera preview ───────────────────────────────────────────────
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

          // ── Dim overlay ──────────────────────────────────────────────────
          Container(color: Colors.black.withValues(alpha: 0.12)),

          // ── Countdown timer ──────────────────────────────────────────────
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

          // ── Scan box ─────────────────────────────────────────────────────
          Center(
            child: Container(
              width: size.width * 0.62,
              height: size.width * 0.62,
              decoration: BoxDecoration(
                color: const Color(0xFF58D68D).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _engine.state == _FlapState.open
                      ? Colors.orangeAccent
                      : const Color(0xFF58D68D),
                  width: 4,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Slot indicator
                  Positioned(
                    top: 24,
                    child: Container(
                      width: size.width * 0.30,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFF58D68D),
                          width: 4,
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: size.width * 0.18,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFF58D68D).withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Record indicator dot
                  Positioned(
                    top: 26,
                    right: 14,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Color(0xFF58D68D),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.radio_button_checked,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  // Status text
                  Positioned(
                    bottom: 32,
                    left: 16,
                    right: 16,
                    child: Text(
                      _calibrating
                          ? 'Calibrating…'
                          : _engine.state == _FlapState.open
                              ? 'Detecting…'
                              : 'Ready — insert bottle',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _engine.state == _FlapState.open
                            ? Colors.orangeAccent
                            : const Color(0xFF58D68D).withValues(alpha: 0.95),
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── NEW: AR animated downward arrow ──────────────────────────────
          // Shows the correct insertion direction — fades out when detecting
          AnimatedBuilder(
            animation: Listenable.merge([_arrowBounce, _arrowFadeCtrl]),
            builder: (context, _) {
              return Positioned(
                // Positioned just above centre — over the slot opening
                top: size.height * 0.12 + _arrowBounce.value,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: _arrowFadeCtrl.value,
                  child: Center(
                    child: _ArrowIndicator(size: size),
                  ),
                ),
              );
            },
          ),

          // ── Calibration progress bar ──────────────────────────────────────
          if (_calibrating)
            Positioned(
              top: 110,
              left: 32,
              right: 32,
              child: Column(
                children: [
                  const Text(
                    'Calibrating flap — keep slot clear',
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
                ],
              ),
            ),

          // ── Shake-rejected indicator ──────────────────────────────────────
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
                      Text(
                        'Camera moved — hold steady',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Bottom instruction ────────────────────────────────────────────
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
}

// ══════════════════════════════════════════════════════════════════════════════
// AR Arrow Indicator Widget
// Draws a downward-pointing arrow with a glowing outline to guide bottle insertion
// ══════════════════════════════════════════════════════════════════════════════
class _ArrowIndicator extends StatelessWidget {
  const _ArrowIndicator({required this.size});
  final Size size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size.width * 0.22, size.width * 0.22),
      painter: _DownArrowPainter(),
    );
  }
}

class _DownArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double stemW = size.width * 0.22;
    final double stemTop = 0;
    final double stemBottom = size.height * 0.58;
    final double headTop = size.height * 0.44;
    final double headBottom = size.height;
    final double headHalfW = size.width / 2;

    // Arrow path (pointing downward)
    final path = Path()
      ..moveTo(cx - stemW / 2, stemTop)           // top-left of stem
      ..lineTo(cx + stemW / 2, stemTop)           // top-right of stem
      ..lineTo(cx + stemW / 2, headTop)           // right side down to head
      ..lineTo(cx + headHalfW, headTop)           // right wing
      ..lineTo(cx, headBottom)                    // bottom point
      ..lineTo(cx - headHalfW, headTop)           // left wing
      ..lineTo(cx - stemW / 2, headTop)           // back to stem
      ..close();

    // Glow shadow
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF58D68D).withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // Fill
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFF58D68D).withOpacity(0.85),
    );

    // Outline
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(_DownArrowPainter old) => false;
}