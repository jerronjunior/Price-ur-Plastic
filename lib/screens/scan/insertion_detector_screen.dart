import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'slot_motion_detection_impl.dart';

// ══════════════════════════════════════════════════════════════════════════════
// _SlotTracker  v3 — pixel-level centroid (finds the tan flap position)
// ══════════════════════════════════════════════════════════════════════════════
class _SlotTracker {
  static const double _scanTop    = 0.02;
  static const double _scanBottom = 0.65;
  static const double _minY       = 88.0;
  static const double _maxY       = 205.0;
  static const double _minV       = 130.0;
  static const int    _minPixels  = 20;
  static const double _deltaY     = 8.0;
  static const int    _lockFrames  = 4;
  static const double _seekAlpha   = 0.35;
  static const double _lockedAlpha = 0.05;
  static const double _unlockDist  = 0.20;

  double slotNormX = 0.50; // normalised in RAW CAMERA image coords
  double slotNormY = 0.28;
  bool   hasLock   = false;

  int    _streak = 0;
  bool   _locked = false;
  double _lockX  = 0.50;
  double _lockY  = 0.28;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List? vPlane =
        image.planes.length > 2 ? image.planes[2].bytes : null;
    final int uvRowStride = image.planes.length > 2
        ? image.planes[2].bytesPerRow : (fw ~/ 2);

    final int py0 = (_scanTop * fh).toInt();
    final int py1 = (_scanBottom * fh).toInt();

    double ambientSum = 0; int ambientCnt = 0;
    for (int py = py0; py < py1; py += 8) {
      for (int px = 0; px < fw; px += 8) {
        final int yi = py * fw + px;
        if (yi < yPlane.length) { ambientSum += yPlane[yi]; ambientCnt++; }
      }
    }
    final double ambientY = ambientCnt > 0 ? ambientSum / ambientCnt : 100;
    final double threshold = ambientY + _deltaY;

    double wSumX = 0, wSumY = 0, wTotal = 0;
    int pixelCount = 0;
    for (int py = py0; py < py1; py += 4) {
      for (int px = 0; px < fw; px += 4) {
        final int yi = py * fw + px;
        if (yi >= yPlane.length) continue;
        final double yVal = yPlane[yi].toDouble();
        if (yVal < _minY || yVal > _maxY || yVal < threshold) continue;
        if (vPlane != null) {
          final int vi = (py ~/ 2) * uvRowStride + (px ~/ 2);
          if (vi < vPlane.length && vPlane[vi].toDouble() < _minV) continue;
        }
        wSumX += px * yVal; wSumY += py * yVal;
        wTotal += yVal; pixelCount++;
      }
    }

    final bool detected = pixelCount >= _minPixels && wTotal > 0;
    if (!detected) {
      _streak = (_streak - 1).clamp(0, _lockFrames);
      if (_streak == 0) { _locked = false; hasLock = false; }
      return;
    }

    final double rawX = (wSumX / wTotal) / fw;
    final double rawY = (wSumY / wTotal) / fh;

    if (_locked) {
      final double d = _hypot(rawX - _lockX, rawY - _lockY);
      if (d > _unlockDist) { hasLock = true; return; }
    }

    _streak = (_streak + 1).clamp(0, _lockFrames + 1);
    if (_streak >= _lockFrames && !_locked) {
      _locked = true; _lockX = slotNormX; _lockY = slotNormY;
    }
    final double alpha = _locked ? _lockedAlpha : _seekAlpha;
    slotNormX += (rawX - slotNormX) * alpha;
    slotNormY += (rawY - slotNormY) * alpha;
    if (_locked) {
      _lockX += (rawX - _lockX) * 0.008;
      _lockY += (rawY - _lockY) * 0.008;
    }
    hasLock = true;
  }

  // ── KEY FIX: Convert camera-space coords → screen-space coords ─────────────
  //
  // Camera images come from the sensor in LANDSCAPE orientation.
  // The phone is held in PORTRAIT.  CameraPreview rotates the display
  // automatically, but the raw CameraImage bytes are NOT rotated.
  //
  // For sensorOrientation = 90 (most Android back cameras):
  //   camera_x  →  screen_y          (camera's X axis = top→bottom on screen)
  //   camera_y  →  screen_x flipped  (camera's Y axis = right→left on screen)
  //
  // Formula for 90°:  screenX = 1 - camY,  screenY = camX
  // Formula for 270°: screenX = camY,       screenY = 1 - camX
  // Formula for 0°/180°: identity / flip
  //
  Offset toScreenOffset(Size screenSize, int sensorOrientation) {
    final double cx = slotNormX;
    final double cy = slotNormY;
    double sx, sy;
    switch (sensorOrientation) {
      case 90:
        sx = 1.0 - cy;
        sy = cx;
        break;
      case 270:
        sx = cy;
        sy = 1.0 - cx;
        break;
      case 180:
        sx = 1.0 - cx;
        sy = 1.0 - cy;
        break;
      default: // 0 — iOS, or already portrait sensor
        sx = cx;
        sy = cy;
    }
    return Offset(
      sx.clamp(0.05, 0.95) * screenSize.width,
      sy.clamp(0.05, 0.90) * screenSize.height,
    );
  }

  // Also expose the slot region in camera-normalised coords for the
  // motion detector (it needs camera-space, not screen-space).
  // The slot region is a rectangle centred on the tracked point.
  ({double left, double top, double width, double height}) get cameraRegion {
    const double hw = 0.18; // half-width in camera coords
    const double hh = 0.15; // half-height in camera coords
    return (
      left:   (slotNormX - hw).clamp(0.0, 0.80),
      top:    (slotNormY - hh).clamp(0.0, 0.80),
      width:  hw * 2,
      height: hh * 2,
    );
  }

  double _hypot(double a, double b) => sqrt(a * a + b * b);

  void reset() {
    slotNormX = 0.50; slotNormY = 0.28;
    hasLock = false; _locked = false;
    _lockX = 0.50; _lockY = 0.28; _streak = 0;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// InsertionDetectorScreen
//
// WHAT CHANGED vs the old version:
//
// 1. ARROW FIX — toScreenOffset() applies the sensor orientation transform
//    so the arrow tip actually lands on the bin slot in the preview.
//
// 2. DETECTION FIX — uses SlotMotionDetectionImpl (frame-differencing +
//    downward motion state machine) instead of the brightness-only FlapEngine.
//    SlotMotionDetectionImpl works on both iOS and Android, and detects the
//    actual motion of the bottle passing through — not just brightness changes.
//
// 3. DYNAMIC REGION — every time the slot tracker moves, the motion detector's
//    region is updated to follow the slot, so detection always covers the
//    correct part of the frame.
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
  CameraDescription? _camDesc;
  bool _cameraReady     = false;
  bool _processingFrame = false;
  int  _frameCount      = 0;
  bool _detected        = false;

  // ── Slot tracker — finds where the flap is ─────────────────────────────────
  final _SlotTracker _tracker = _SlotTracker();

  // ── Motion detector — detects bottle passing through ──────────────────────
  SlotMotionDetectionImpl? _motionDetector;
  bool _motionReady     = false; // calibrated and ready
  bool _streamStarted   = false;

  // How many frames we've had lock before allowing detection
  int  _stableFrames    = 0;
  static const int _requiredStableFrames = 8;

  // ── Timeout ────────────────────────────────────────────────────────────────
  Timer? _timeoutTimer;
  late int _remainingSeconds;

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _dotCtrl;
  late AnimationController _flashCtrl;
  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    _dotCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();

    _flashCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));

    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _dotCtrl.dispose();
    _flashCtrl.dispose();
    _motionDetector?.dispose();
    if (_streamStarted && _cam?.value.isStreamingImages == true) {
      _cam?.stopImageStream();
    }
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

    _camDesc = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _cam = CameraController(
      _camDesc!,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cam!.initialize();
      try {
        final min = await _cam!.getMinZoomLevel();
        final max = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel(
            (min <= 1.0 && max >= 1.0) ? 1.0 : min);
      } catch (_) {}

      if (!mounted) return;
      setState(() { _cameraReady = true; _stableFrames = 0; });
      _tracker.reset();
      _buildMotionDetector();

      await _cam!.startImageStream(_onFrame);
      _streamStarted = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  // Build / rebuild the motion detector with the current slot region
  void _buildMotionDetector() {
    _motionDetector?.dispose();
    final r = _tracker.cameraRegion;
    _motionDetector = SlotMotionDetectionImpl(
      regionLeft:   r.left,
      regionTop:    r.top,
      regionWidth:  r.width,
      regionHeight: r.height,
      onReadyChanged: (ready) {
        if (!mounted) return;
        setState(() => _motionReady = ready);
      },
      onMotionDetected: _onBottleDetected,
    );
  }

  // Called by SlotMotionDetectionImpl when a bottle passes through
  void _onBottleDetected() {
    if (_detected || !mounted) return;
    if (_stableFrames < _requiredStableFrames) return;
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

  // ── Frame processing ────────────────────────────────────────────────────────
  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _detected) return;
    _processingFrame = true;

    try {
      // 1. Update slot tracker
      _tracker.update(image);

      // 2. Track stable lock frames
      if (_tracker.hasLock) {
        _stableFrames++;
        // When lock first stabilises, rebuild motion detector with correct region
        if (_stableFrames == _requiredStableFrames) {
          _buildMotionDetector();
        }
        // Periodically update the region to follow the slot as camera moves
        if (_stableFrames % 15 == 0) {
          _buildMotionDetector();
        }
      } else {
        _stableFrames = 0;
      }

      // 3. Feed frame to motion detector
      _motionDetector?.processImage(image);

      if (mounted) setState(() {});
    } finally {
      _processingFrame = false;
    }
  }

  // ── Status text ─────────────────────────────────────────────────────────────
  String get _statusText {
    if (!_tracker.hasLock)                    return 'Point camera at the bin slot';
    if (_stableFrames < _requiredStableFrames) return 'Locking on slot…';
    if (!_motionReady)                        return 'Calibrating motion…';
    return 'Ready — insert bottle now';
  }

  // ── Sensor orientation ──────────────────────────────────────────────────────
  int get _sensorOrientation => _camDesc?.sensorOrientation ?? 90;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Insert Bottle',
            style: TextStyle(color: Colors.white,
                fontSize: 22, fontWeight: FontWeight.w500)),
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

      // ── FIX: apply sensor orientation transform ───────────────────────────
      final Offset target = _tracker.toScreenOffset(size, _sensorOrientation);

      // Arrow pivot fixed at lower-center of screen
      final Offset pivot = Offset(size.width * 0.50, size.height * 0.72);

      // Angle from pivot to target — arrow tip points at the slot
      final double dx = target.dx - pivot.dx;
      final double dy = target.dy - pivot.dy;
      final double deviation = atan2(dx, -dy); // 0 = straight up

      // Amplify so small real movements = big visible arrow swings
      const double amplification = 3.0;
      final double angle =
          (deviation * amplification).clamp(-pi * 0.78, pi * 0.78);

      final bool lockedAndReady =
          _tracker.hasLock &&
          _stableFrames >= _requiredStableFrames &&
          _motionReady;

      return Stack(fit: StackFit.expand, children: [

        // Camera
        Positioned.fill(child: CameraPreview(_cam!)),
        Container(color: Colors.black.withValues(alpha: 0.08)),

        // Flash on count
        if (_showFlash)
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, __) => Opacity(
              opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
              child: Container(
                  color: Colors.white.withValues(alpha: 0.40)),
            ),
          ),

        // 3D game arrow
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (context, _) => CustomPaint(
            size: size,
            painter: _GameArrowPainter(
              pivot:       pivot,
              angle:       angle,
              animValue:   _dotCtrl.value,
              isDetecting: _motionReady && lockedAndReady,
              hasLock:     lockedAndReady,
              target:      target,
            ),
          ),
        ),

        // Countdown
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
              child: Text('$_remainingSeconds',
                  style: TextStyle(
                    color: _remainingSeconds <= 5
                        ? Colors.redAccent : Colors.white,
                    fontSize: 32, fontWeight: FontWeight.w700,
                  )),
            ),
          ),
        ),

        // Warning: no lock
        if (!_tracker.hasLock)
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
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.center_focus_weak,
                      color: Colors.white70, size: 14),
                  SizedBox(width: 6),
                  Text('Point camera at the bin slot',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
            ),
          ),

        // Status label
        Positioned(
          bottom: 88, left: 0, right: 0,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(_statusText,
                  key: ValueKey(_statusText),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                  )),
            ),
          ),
        ),

        // Bottom instruction
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Arrow points at the bin slot.\nInsert bottle — counted automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _GameArrowPainter (unchanged)
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
  final double angle;
  final double animValue;
  final bool   isDetecting;
  final bool   hasLock;
  final Offset target;

  static const Color _red       = Color(0xFFE53935);
  static const Color _orange    = Color(0xFFFF6B35);
  static const Color _darkRed   = Color(0xFF7B0000);
  static const Color _darkest   = Color(0xFF3E0000);
  static const Color _highlight = Color(0xFFFF8A80);

  Color  get _main => isDetecting ? _orange : _red;
  Color  get _dark => isDetecting ? const Color(0xFF8B3000) : _darkRed;
  Color  get _edge => isDetecting ? const Color(0xFF3E1500) : _darkest;
  double get _go   => hasLock ? 0.93 : 0.38;
  static const double _ao = 0.30;

  @override
  void paint(Canvas canvas, Size size) {
    final double pulse = isDetecting
        ? 1.0 + sin(animValue * pi * 4) * 0.06 : 1.0;

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(angle);
    canvas.scale(pulse, pulse);
    _drawArrow(canvas);
    canvas.restore();
    _drawRing(canvas);
  }

  void _drawArrow(Canvas canvas) {
    const double tipY      = -96.0;
    const double shoulderY = -34.0;
    const double bodyBotY  =  38.0;
    const double baseBotY  =  56.0;
    const double headHW    =  52.0;
    const double bodyTopHW =  22.0;
    const double bodyBotHW =  28.0;
    const double depth     =   8.0;
    final double o = _go * _ao;

    canvas.drawPath(
      Path()
        ..moveTo(-bodyBotHW, baseBotY) ..lineTo(bodyBotHW, baseBotY)
        ..lineTo(bodyBotHW + depth, baseBotY + depth)
        ..lineTo(-bodyBotHW + depth, baseBotY + depth) ..close(),
      Paint()..color = _edge.withValues(alpha: 0.85 * o));

    canvas.drawPath(
      Path()
        ..moveTo(-bodyTopHW, shoulderY)
        ..lineTo(-bodyTopHW - depth, shoulderY + depth)
        ..lineTo(-bodyBotHW - depth, bodyBotY + depth)
        ..lineTo(-bodyBotHW, bodyBotY) ..close(),
      Paint()..color = _dark.withValues(alpha: 0.80 * o));

    final Path front = Path()
      ..moveTo(0, tipY)
      ..lineTo(headHW, shoulderY) ..lineTo(bodyTopHW, shoulderY)
      ..lineTo(bodyBotHW, bodyBotY) ..lineTo(bodyBotHW, baseBotY)
      ..lineTo(-bodyBotHW, baseBotY) ..lineTo(-bodyBotHW, bodyBotY)
      ..lineTo(-bodyTopHW, shoulderY) ..lineTo(-headHW, shoulderY)
      ..close();
    canvas.drawPath(front,
        Paint()..color = _main.withValues(alpha: 0.96 * o));

    canvas.drawPath(
      Path()
        ..moveTo(0, tipY) ..lineTo(headHW, shoulderY)
        ..lineTo(headHW * 0.55, shoulderY) ..close(),
      Paint()..color = _highlight.withValues(alpha: 0.35 * o));

    canvas.drawPath(front,
      Paint()
        ..color = Colors.black.withValues(alpha: hasLock ? 0.82 : 0.68)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round);
  }

  void _drawRing(Canvas canvas) {
    final double pulse = isDetecting
        ? 0.5 + sin(animValue * pi * 5) * 0.5
        : hasLock ? 0.5 + sin(animValue * pi * 2) * 0.3 : 0.2;

    final Color rc = isDetecting ? _orange : _red;
    final double r = 20.0 + pulse * 8;
    final double o = _go;

    canvas.drawCircle(target, r,
      Paint()
        ..color = rc.withValues(alpha: (0.78 + pulse * 0.22) * o)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hasLock ? 2.8 : 1.5);

    canvas.drawCircle(target, hasLock ? 4.5 : 2.5,
        Paint()..color = rc.withValues(alpha: 0.95 * o));

    final double arm = hasLock ? 13.0 : 8.0;
    const double gap = 6.0;
    final Paint lp = Paint()
      ..color = rc.withValues(alpha: 0.80 * o)
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

    if (hasLock) {
      final String label = isDetecting ? 'BOTTLE IN!' : 'SLOT READY';
      final tp = TextPainter(
        text: TextSpan(text: label,
          style: TextStyle(
            color: rc.withValues(alpha: 0.85 * o),
            fontSize: isDetecting ? 12 : 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 5)],
          )),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(target.dx - tp.width / 2, target.dy + r + 8));
    }
  }

  @override
  bool shouldRepaint(_GameArrowPainter old) =>
      old.pivot != pivot || old.angle != angle ||
      old.animValue != animValue || old.isDetecting != isDetecting ||
      old.hasLock != hasLock || old.target != target;
}