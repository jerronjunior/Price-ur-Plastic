import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// ══════════════════════════════════════════════════════════════════════════════
// _SlotTracker  v3 — pixel-level centroid (unchanged, works well)
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

  double slotNormX = 0.50;
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

    // Pass 1: ambient brightness
    double ambientSum = 0; int ambientCnt = 0;
    for (int py = py0; py < py1; py += 8) {
      for (int px = 0; px < fw; px += 8) {
        final int yi = py * fw + px;
        if (yi < yPlane.length) { ambientSum += yPlane[yi]; ambientCnt++; }
      }
    }
    final double ambientY = ambientCnt > 0 ? ambientSum / ambientCnt : 100;
    final double threshold = ambientY + _deltaY;

    // Pass 2+3: weighted centroid of tan flap pixels
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
    if (_locked) { _lockX += (rawX - _lockX) * 0.008; _lockY += (rawY - _lockY) * 0.008; }
    hasLock = true;
  }

  double _hypot(double a, double b) => sqrt(a * a + b * b);

  void reset() {
    slotNormX = 0.50; slotNormY = 0.28;
    hasLock = false; _locked = false;
    _lockX = 0.50; _lockY = 0.28; _streak = 0;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _FlapEngine
//
// HOW THE COUNTING WORKS (simple version):
//
//   The bin slot has a tan/brown flap with a downward arrow on it.
//   When a bottle is inserted, it pushes the flap → flap swings open.
//   The flap blocks light → the zone goes DARK for ~0.5–2 seconds.
//   When the bottle falls through, the flap closes → zone goes BRIGHT again.
//
//   BRIGHT → DARK (≥500ms) → BRIGHT AGAIN = 1 bottle counted ✅
//
// SHAKE REJECTION:
//   A reference zone beside the flap is also monitored.
//   Camera shake changes BOTH zones equally.
//   A real bottle only darkens the FLAP zone.
//   → If both change = camera shake = ignored ❌
//   → If only flap zone changes = real bottle = counted ✅
//
// TIMING:
//   _minHiddenMs = 500   minimum time flap must stay dark (rejects fast shadows)
//   _maxHiddenMs = 3000  maximum time (longer = hand blocking, not a bottle)
//   _cooldownMs  = 2500  wait before allowing next count (no double-count)
// ══════════════════════════════════════════════════════════════════════════════
enum _FlapState {
  idle,   // flap is visible (bright) — waiting for bottle
  hidden, // flap is dark — bottle is going through
}

class _FlapEngine {
  // Detection zones — updated every frame to follow the tracked slot
  Rect zone          = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);
  Rect referenceZone = const Rect.fromLTRB(0.78, 0.20, 0.96, 0.55);

  // Calibration baselines
  double baselineBrightness          = 0;
  double baselineReferenceBrightness = 0;
  bool   isCalibrated                = false;

  // How much darker than baseline = "flap is hidden"
  // 0.25 = zone must drop 25% below baseline
  // Increase if false triggers; decrease if real bottles are missed
  double darkThresholdFraction = 0.25;

  // Shake rejection: if reference zone changes by more than this → camera moved
  static const double _shakeRejectFraction = 0.12;

  // ── Timing ─────────────────────────────────────────────────────────────────
  // Minimum ms flap must stay dark to count — rejects fast shadows
  static const int _minHiddenMs = 500;
  // Maximum ms — if dark longer, it's a hand blocking not a bottle
  static const int _maxHiddenMs = 3000;
  // Cooldown after each count — prevents double counting
  static const int _cooldownMs  = 2500;

  // State
  _FlapState state              = _FlapState.idle;
  double     currentBrightness = 0;
  double     currentReferenceBrightness = 0;
  bool       lastRejectedByShake = false;
  DateTime?  _hiddenSince;
  DateTime?  _lastCount;

  bool get inCooldown {
    if (_lastCount == null) return false;
    return DateTime.now().difference(_lastCount!).inMilliseconds < _cooldownMs;
  }

  // The brightness level below which we say "flap is hidden/dark"
  double get darkThreshold =>
      baselineBrightness * (1.0 - darkThresholdFraction);

  // ── Main detection — called every processed camera frame ──────────────────
  //
  // Returns TRUE when a bottle insertion is confirmed.
  // This is the ONLY place that triggers a count.
  //
  bool processFrame(CameraImage image) {
    if (!isCalibrated || inCooldown) return false;

    // Measure brightness of flap zone and reference zone
    currentBrightness          = _brightness(image, zone);
    currentReferenceBrightness = _brightness(image, referenceZone);

    // ── Shake check ──────────────────────────────────────────────────────────
    // If the reference zone also changed a lot → camera moved, not a bottle
    if (baselineReferenceBrightness > 0) {
      final double refChange =
          (currentReferenceBrightness - baselineReferenceBrightness).abs() /
          baselineReferenceBrightness;
      if (refChange > _shakeRejectFraction) {
        lastRejectedByShake = true;
        // Reset state — don't count anything while shaking
        state       = _FlapState.idle;
        _hiddenSince = null;
        return false;
      }
    }
    lastRejectedByShake = false;

    // Is the flap currently dark (hidden by bottle)?
    final bool flapHidden = currentBrightness < darkThreshold;

    switch (state) {

      // ── IDLE: flap is visible, waiting for a bottle ─────────────────────
      case _FlapState.idle:
        if (flapHidden) {
          // Flap just went dark — bottle is entering
          state        = _FlapState.hidden;
          _hiddenSince = DateTime.now();
        }
        break;

      // ── HIDDEN: flap is dark, bottle is passing through ─────────────────
      case _FlapState.hidden:
        if (flapHidden) {
          // Still dark — check if it's been too long (hand blocking)
          final int hiddenMs = DateTime.now()
              .difference(_hiddenSince!)
              .inMilliseconds;
          if (hiddenMs > _maxHiddenMs) {
            // Dark for too long = hand or object blocking, not a bottle
            state        = _FlapState.idle;
            _hiddenSince = null;
          }
          // Otherwise keep waiting — bottle is still passing through
        } else {
          // ✅ Flap just became visible again — bottle has dropped in!
          final int hiddenMs = DateTime.now()
              .difference(_hiddenSince!)
              .inMilliseconds;

          state        = _FlapState.idle;
          _hiddenSince = null;

          if (hiddenMs < _minHiddenMs) {
            // Was dark for too short — just a shadow or flicker, not a bottle
            return false;
          }

          // Perfect: flap was dark for 500ms–3000ms then reopened = bottle in!
          _lastCount = DateTime.now();
          return true; // ✅ COUNT +1
        }
        break;
    }
    return false;
  }

  // ── Calibration ───────────────────────────────────────────────────────────
  // Called 25 times with the flap visible and slot empty.
  // Learns what "normal brightness" looks like.
  void addCalibrationSample(CameraImage image) {
    final double b = _brightness(image, zone);
    final double r = _brightness(image, referenceZone);
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

  // ── Zone brightness helper ────────────────────────────────────────────────
  double _brightness(CameraImage image, Rect z) {
    final int fw = image.width;
    final int fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;
    final int x0 = (z.left   * fw).toInt().clamp(0, fw - 1);
    final int y0 = (z.top    * fh).toInt().clamp(0, fh - 1);
    final int x1 = (z.right  * fw).toInt().clamp(0, fw - 1);
    final int y1 = (z.bottom * fh).toInt().clamp(0, fh - 1);
    double sum = 0; int count = 0;
    for (int py = y0; py < y1; py += 4) {
      for (int px = x0; px < x1; px += 4) {
        final int idx = py * fw + px;
        if (idx < yPlane.length) { sum += yPlane[idx]; count++; }
      }
    }
    return count > 0 ? sum / count : 128;
  }

  void reset() {
    state              = _FlapState.idle;
    _hiddenSince       = null;
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

  CameraController? _cam;
  bool _cameraReady     = false;
  bool _processingFrame = false;
  int  _frameCount      = 0;
  bool _detected        = false;

  final _FlapEngine  _engine  = _FlapEngine();
  final _SlotTracker _tracker = _SlotTracker();

  bool _calibrating       = false;
  int  _calibrationFrames = 0;
  static const int _calibrationFrameCount = 25;

  // Lock must be stable for this many frames before detection starts
  // Prevents false counts right when lock is first acquired
  int _stableFrames = 0;
  static const int _requiredStableFrames = 8;

  Timer? _timeoutTimer;
  late int _remainingSeconds;

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
      try {
        final min = await _cam!.getMinZoomLevel();
        final max = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel(
            (min <= 1.0 && max >= 1.0) ? 1.0 : min);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _cameraReady                        = true;
        _calibrating                        = true;
        _calibrationFrames                  = 0;
        _stableFrames                       = 0;
        _engine.baselineBrightness          = 0;
        _engine.baselineReferenceBrightness = 0;
        _engine.isCalibrated                = false;
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

  // ── Frame processing ────────────────────────────────────────────────────────
  void _onFrame(CameraImage image) {
    _frameCount++;
    // Process every 2nd frame (~15fps) — fast enough, saves battery
    if (_frameCount % 2 != 0 || _processingFrame || _detected) return;
    _processingFrame = true;

    try {
      // 1. Update slot tracker — finds where the tan flap is in the frame
      _tracker.update(image);

      // 2. Track how many consecutive frames we have had a stable lock
      if (_tracker.hasLock) {
        _stableFrames++;
      } else {
        _stableFrames = 0;
        // Lost the slot — reset calibration so we re-calibrate when it returns
        if (_engine.isCalibrated) {
          _engine.reset();
          _engine.baselineBrightness          = 0;
          _engine.baselineReferenceBrightness = 0;
          _engine.isCalibrated                = false;
          _calibrating                        = true;
          _calibrationFrames                  = 0;
        }
      }

      // 3. Keep detection zones centered on the tracked slot
      _syncZones();

      // 4. Calibration mode — learn the baseline brightness of the flap
      if (_calibrating) {
        // Only calibrate when tracker has a stable lock on the flap
        if (!_tracker.hasLock) { if (mounted) setState(() {}); return; }

        _engine.addCalibrationSample(image);
        _calibrationFrames++;

        if (_calibrationFrames >= _calibrationFrameCount) {
          _engine.finalizeCalibration();
          if (mounted) setState(() {
            _calibrating       = false;
            _calibrationFrames = 0;
          });
        } else {
          if (mounted) setState(() {});
        }
        return;
      }

      // 5. Not ready to detect yet — wait for stable lock
      if (!_engine.isCalibrated ||
          !_tracker.hasLock ||
          _stableFrames < _requiredStableFrames) {
        if (mounted) setState(() {});
        return;
      }

      // 6. ✅ MAIN DETECTION — this is where bottles are counted
      //    processFrame() returns true ONLY when:
      //    - The flap zone went dark (bottle covering it)
      //    - Stayed dark for 500ms–3000ms
      //    - Then went bright again (bottle dropped in)
      //    - Camera wasn't shaking during this time
      final bool bottleCounted = _engine.processFrame(image);
      if (mounted) setState(() {});

      if (bottleCounted) {
        _detected = true;
        _timeoutTimer?.cancel();

        // Flash animation
        _showFlash = true;
        _flashCtrl.forward(from: 0).then((_) {
          if (mounted) setState(() => _showFlash = false);
        });

        // Small delay so user sees the flash, then call onDetected
        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) widget.onDetected();
        });
      }
    } finally {
      _processingFrame = false;
    }
  }

  // Keep detection zone tightly around the tracked slot
  void _syncZones() {
    final double cx = _tracker.slotNormX.clamp(0.08, 0.92);
    final double cy = _tracker.slotNormY.clamp(0.08, 0.62);
    const double zW = 0.14, zH = 0.16;

    _engine.zone = Rect.fromLTRB(
      (cx - zW / 2).clamp(0.02, 0.84),
      (cy - zH / 2).clamp(0.02, 0.70),
      (cx + zW / 2).clamp(0.16, 0.98),
      (cy + zH / 2).clamp(0.06, 0.78),
    );

    const double rOffX = 0.18, rW = 0.12, rH = 0.16;
    final double rcx = (cx + rOffX).clamp(0.10, 0.92);
    _engine.referenceZone = Rect.fromLTRB(
      (rcx - rW / 2).clamp(0.02, 0.86),
      (cy  - rH / 2).clamp(0.02, 0.70),
      (rcx + rW / 2).clamp(0.14, 0.98),
      (cy  + rH / 2).clamp(0.06, 0.80),
    );
  }

  String get _statusText {
    if (_calibrating)                         return 'Calibrating…';
    if (_engine.lastRejectedByShake)          return 'Hold camera steady';
    if (!_engine.isCalibrated)                return 'Getting ready…';
    if (!_tracker.hasLock)                    return 'Point camera at the bin slot';
    if (_stableFrames < _requiredStableFrames) return 'Locking on slot…';
    if (_engine.state == _FlapState.hidden)   return 'Bottle detected…';
    return 'Ready — insert bottle now';
  }

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

      final double targetX =
          (_tracker.slotNormX.clamp(0.0, 1.0) * size.width)
              .clamp(size.width * 0.05, size.width * 0.95);
      final double targetY =
          (_tracker.slotNormY.clamp(0.0, 1.0) * size.height)
              .clamp(size.height * 0.05, size.height * 0.95);

      return Stack(fit: StackFit.expand, children: [

        // Camera preview
        Positioned.fill(child: CameraPreview(_cam!)),
        Container(color: Colors.black.withValues(alpha: 0.08)),

        // White flash when bottle counted
        if (_showFlash)
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, __) => Opacity(
              opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
              child: Container(color: Colors.white.withValues(alpha: 0.40)),
            ),
          ),

        // 3D game arrow pointing at the slot
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (context, _) {
            final Offset pivot =
                Offset(size.width * 0.50, size.height * 0.72);
            final double dx = targetX - pivot.dx;
            final double dy = targetY - pivot.dy;
            final double deviation = atan2(dx, -dy);
            const double amplification = 3.0;
            final double angle =
                (deviation * amplification).clamp(-pi * 0.78, pi * 0.78);

            return CustomPaint(
              size: size,
              painter: _GameArrowPainter(
                pivot:       pivot,
                angle:       angle,
                animValue:   _dotCtrl.value,
                isDetecting: _engine.state == _FlapState.hidden,
                hasLock:     _tracker.hasLock &&
                    _stableFrames >= _requiredStableFrames,
                target:      Offset(targetX, targetY),
              ),
            );
          },
        ),

        // Countdown timer
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

        // Calibration progress bar
        if (_calibrating)
          Positioned(
            top: 108, left: 32, right: 32,
            child: Column(children: [
              const Text('Calibrating — keep slot visible and clear',
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

        // Shake warning / no lock warning
        if (!_calibrating &&
            (_engine.lastRejectedByShake || !_tracker.hasLock))
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
                    color: Colors.white70, size: 14,
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
          left: 24, right: 24, bottom: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              'Point camera at the bin slot.\nInsert bottle — count increases when the flap opens then closes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
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