import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'slot_motion_detection_impl.dart';
import 'sound_spike_detector.dart';
import '../../services/training_data_service.dart';

// ══════════════════════════════════════════════════════════════════════════════
// _SlotTracker  v3 — pixel-level centroid
// Finds the exact center of the tan/amber bin flap in every camera frame.
// ══════════════════════════════════════════════════════════════════════════════
class _SlotTracker {
  static const double _scanTop = 0.02;
  static const double _scanBottom = 0.65;
  static const double _minY = 88.0;
  static const double _maxY = 205.0;
  static const double _minV = 130.0;
  static const int _minPixels = 20;
  static const double _deltaY = 8.0;
  static const int _lockFrames = 4;
  static const double _seekAlpha = 0.35;
  static const double _lockedAlpha = 0.05;
  static const double _unlockDist = 0.20;

  double slotNormX = 0.50;
  double slotNormY = 0.28;
  bool hasLock = false;

  int _streak = 0;
  bool _locked = false;
  double _lockX = 0.50;
  double _lockY = 0.28;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List? vPlane =
        image.planes.length > 2 ? image.planes[2].bytes : null;
    final int uvRowStride =
        image.planes.length > 2 ? image.planes[2].bytesPerRow : (fw ~/ 2);

    final int py0 = (_scanTop * fh).toInt();
    final int py1 = (_scanBottom * fh).toInt();

    double ambientSum = 0;
    int ambientCnt = 0;
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
        wSumX += px * yVal;
        wSumY += py * yVal;
        wTotal += yVal;
        pixelCount++;
      }
    }

    final bool detected = pixelCount >= _minPixels && wTotal > 0;
    if (!detected) {
      _streak = (_streak - 1).clamp(0, _lockFrames);
      if (_streak == 0) {
        _locked = false;
        hasLock = false;
      }
      return;
    }

    final double rawX = (wSumX / wTotal) / fw;
    final double rawY = (wSumY / wTotal) / fh;

    if (_locked) {
      if (_hypot(rawX - _lockX, rawY - _lockY) > _unlockDist) {
        hasLock = true;
        return;
      }
    }

    _streak = (_streak + 1).clamp(0, _lockFrames + 1);
    if (_streak >= _lockFrames && !_locked) {
      _locked = true;
      _lockX = slotNormX;
      _lockY = slotNormY;
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

  // Convert raw camera coords → screen coords (handles sensor rotation)
  Offset toScreenOffset(Size screen, int sensorOrientation) {
    double sx, sy;
    switch (sensorOrientation) {
      case 90:
        sx = 1.0 - slotNormY;
        sy = slotNormX;
        break;
      case 270:
        sx = slotNormY;
        sy = 1.0 - slotNormX;
        break;
      case 180:
        sx = 1.0 - slotNormX;
        sy = 1.0 - slotNormY;
        break;
      default:
        sx = slotNormX;
        sy = slotNormY;
    }
    return Offset(
      sx.clamp(0.05, 0.95) * screen.width,
      sy.clamp(0.05, 0.90) * screen.height,
    );
  }

  ({double left, double top, double width, double height}) get cameraRegion => (
        left: (slotNormX - 0.18).clamp(0.0, 0.80),
        top: (slotNormY - 0.15).clamp(0.0, 0.80),
        width: 0.36,
        height: 0.30,
      );

  double _hypot(double a, double b) => sqrt(a * a + b * b);

  void reset() {
    slotNormX = 0.50;
    slotNormY = 0.28;
    hasLock = false;
    _locked = false;
    _lockX = 0.50;
    _lockY = 0.28;
    _streak = 0;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _FloatingScore — AR "+N pts" popup that rises from the slot on each count
// ══════════════════════════════════════════════════════════════════════════════
class _FloatingScore {
  final Offset origin;
  final String text;
  final DateTime born;

  const _FloatingScore({
    required this.origin,
    required this.text,
    required this.born,
  });

  static const double _lifetime = 1.8; // seconds

  double get age => DateTime.now().difference(born).inMilliseconds / 1000.0;
  double get progress => (age / _lifetime).clamp(0.0, 1.0);
  bool get isDead => age > _lifetime;
  double get yOffset => -90.0 * Curves.easeOut.transform(progress);
  double get opacity =>
      progress < 0.55 ? progress / 0.55 : 1.0 - (progress - 0.55) / 0.45;
  double get scale => 1.0 + 0.25 * (1.0 - progress);
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
    this.pointsPerBottle = 10,
  });

  final VoidCallback onDetected;
  final VoidCallback onBack;
  final VoidCallback? onTimeout;
  final int timeoutSeconds;
  final int pointsPerBottle;

  @override
  State<InsertionDetectorScreen> createState() =>
      _InsertionDetectorScreenState();
}

class _InsertionDetectorScreenState extends State<InsertionDetectorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  CameraDescription? _camDesc;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _detected = false;

  // ── Detection ──────────────────────────────────────────────────────────────
  final _SlotTracker _tracker = _SlotTracker();
  SlotMotionDetectionImpl? _motion;
  bool _motionReady = false;
  bool _streamStarted = false;
  bool _disposed = false; // guards async camera-frame callbacks
  final SoundSpikeDetector _sound = SoundSpikeDetector();
  int _stableFrames = 0;
  static const int _minStable = 8;

  // ── AR state ───────────────────────────────────────────────────────────────
  int _sessionCount = 0;
  final List<_FloatingScore> _scores = [];
  Timer? _scoreTimer;

  // ── Timeout ────────────────────────────────────────────────────────────────
  Timer? _timeoutTimer;
  late int _remaining;

  // ── Animation controllers ──────────────────────────────────────────────────
  late AnimationController _arCtrl; // drives arrow + reticle (900ms loop)
  late AnimationController _flashCtrl; // white flash (500ms one-shot)
  late AnimationController _badgeCtrl; // count badge bounce (400ms one-shot)

  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remaining = widget.timeoutSeconds;

    _arCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();

    _flashCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));

    _badgeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));

    _startTimeout();
    _initCamera();
    // Fire-and-forget — requests mic permission and starts listening.
    // Never blocks the camera/scanning flow if denied or unsupported.
    unawaited(_sound.start());
  }

  @override
  void dispose() {
    // Set the guard FIRST so any camera frame already in flight on the
    // native thread bails out of _onFrame() immediately instead of calling
    // setState()/touching _motion after they've been torn down. This is
    // what fixes the intermittent '_dependents.isEmpty' assertion.
    _disposed = true;
    _sound.dispose();
    WidgetsBinding.instance.removeObserver(this);

    // Stop the image stream BEFORE disposing anything it feeds into.
    if (_streamStarted && _cam?.value.isStreamingImages == true) {
      try {
        _cam?.stopImageStream();
      } catch (_) {}
    }

    _timeoutTimer?.cancel();
    _scoreTimer?.cancel();
    _arCtrl.dispose();
    _flashCtrl.dispose();
    _badgeCtrl.dispose();
    _motion?.dispose();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) _cam?.dispose();
    if (s == AppLifecycleState.resumed) _initCamera();
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _detected) return;
      setState(() => _remaining--);
      if (_remaining <= 0) {
        _timeoutTimer?.cancel();
        widget.onTimeout != null ? widget.onTimeout!() : widget.onBack();
      }
    });
  }

  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (cams.isEmpty) return;
    _camDesc = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
    _cam = CameraController(_camDesc!, ResolutionPreset.medium,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
    try {
      await _cam!.initialize();
      try {
        final mn = await _cam!.getMinZoomLevel();
        final mx = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel((mn <= 1.0 && mx >= 1.0) ? 1.0 : mn);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _cameraReady = true;
        _stableFrames = 0;
      });
      _tracker.reset();
      _rebuildMotion();
      await _cam!.startImageStream(_onFrame);
      _streamStarted = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  ({double left, double top, double width, double height})? _builtRegion;

  bool _regionDrifted() {
    final b = _builtRegion;
    if (b == null) return true;
    final r = _tracker.cameraRegion;
    return (r.left - b.left).abs() > 0.05 ||
        (r.top - b.top).abs() > 0.05 ||
        (r.width - b.width).abs() > 0.05 ||
        (r.height - b.height).abs() > 0.05;
  }

  void _rebuildMotion() {
    final r = _tracker.cameraRegion;
    _builtRegion = r;
    _motion?.dispose();
    _motion = _buildMotion(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
    );
  }

  // Single place that constructs the calibrated detector — used both for
  // the tracker-refined region and the default no-lock region. This is
  // where the 35-video calibration actually reaches the live app.
  SlotMotionDetectionImpl _buildMotion({
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    return SlotMotionDetectionImpl(
      regionLeft: left,
      regionTop: top,
      regionWidth: width,
      regionHeight: height,
      soundDetector:
          _sound, // fuses sound-spike confirmation with camera motion
      onReadyChanged: (v) {
        if (!_disposed && mounted) setState(() => _motionReady = v);
      },
      onMotionDetected: _onBottleDetected,
      // Report every attempt (counted or rejected) for ongoing self-training.
      onAttemptComplete: (result) {
        TrainingDataService().onInsertionAttempt(
          counted: result.counted,
          rejectedReason: result.rejectedReason,
          peakChangeFraction: result.peakChangeFraction,
          peakDownwardScore: result.peakDownwardScore,
          avgCornerMotion: result.avgCornerMotion,
          durationMs: result.durationMs,
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Bottle inserted callback
  // Called by SlotMotionDetectionImpl when all 5 filters pass:
  //   1. Motion is within the tracked slot zone
  //   2. ≥12% of zone pixels changed
  //   3. Motion direction is downward (not sideways)
  //   4. State machine completed: idle→entering→inside→exiting
  //   5. 2.2s cooldown has elapsed
  // ══════════════════════════════════════════════════════════════════════════
  void _onBottleDetected() {
    if (_detected || _disposed || !mounted) return;
    // NOTE: previously also required _stableFrames >= _minStable (slot lock),
    // but that blocked real insertions on hard-to-track small-hole bins.
    // The SlotMotionDetectionImpl state machine (entering→inside→exiting +
    // corner-motion anti-shake + cooldown) is itself the reliability gate.

    _detected = true;
    _timeoutTimer?.cancel();

    // 1. White flash
    _showFlash = true;
    _flashCtrl.forward(from: 0).then((_) {
      if (mounted) setState(() => _showFlash = false);
    });

    // 2. Session counter increment + badge bounce
    _sessionCount++;
    _badgeCtrl.forward(from: 0);

    // 3. Spawn AR floating score at slot position
    final sz = MediaQuery.of(context).size;
    final origin = _tracker.toScreenOffset(sz, _sensorOrientation);
    _spawnScore(origin);

    // 4. Proceed after short delay (lets flash + popup show first)
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) widget.onDetected();
    });
  }

  void _spawnScore(Offset origin) {
    _scores.add(_FloatingScore(
      origin: origin,
      text: '+${widget.pointsPerBottle} pts',
      born: DateTime.now(),
    ));
    _scoreTimer?.cancel();
    _scoreTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_disposed || !mounted) return;
      _scores.removeWhere((s) => s.isDead);
      if (_scores.isEmpty) _scoreTimer?.cancel();
      if (mounted) setState(() {});
    });
  }

  // ── Frame processing ────────────────────────────────────────────────────────
  void _onFrame(CameraImage image) {
    // Bail immediately if the widget is being/has been torn down — the
    // camera stream runs on a native thread and can deliver a frame after
    // dispose() began. Calling setState() here would throw.
    if (_disposed || !mounted) return;
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _detected) return;
    _processingFrame = true;
    try {
      _tracker.update(image);

      // Slot tracker drives the AR arrow + refines the detection region,
      // but detection must NOT depend on it locking — small-hole bins are
      // hard to track, and waiting for a lock was why insertions were
      // never counted. Ensure _motion always exists; refine its region
      // when the tracker has a good lock, otherwise use a default center
      // region covering the typical bin-slot area.
      if (_tracker.hasLock) {
        _stableFrames++;
        if (_stableFrames == _minStable) _rebuildMotion();
        // Only rebuild when the tracked slot actually MOVED — rebuilding
        // resets the occlusion baseline, and doing that every 15 frames
        // could wipe the arrow reference right as a bottle covers it.
        if (_stableFrames % 15 == 0 && _regionDrifted()) _rebuildMotion();
      } else {
        _stableFrames = 0;
        // No lock yet — make sure a default detector is running so the
        // user can still score while pointing roughly at the slot.
        _motion ??= _buildMotion(
          left: 0.30,
          top: 0.18,
          width: 0.40,
          height: 0.34,
        );
      }
      _motion?.processImage(image);
      if (!_disposed && mounted) setState(() {});
    } finally {
      _processingFrame = false;
    }
  }

  int get _sensorOrientation => _camDesc?.sensorOrientation ?? 90;
  bool get _lockedAndReady =>
      _tracker.hasLock && _stableFrames >= _minStable && _motionReady;

  String get _statusText {
    // Detection runs continuously now (no slot-lock or calibration gate).
    // The live AI probability is embedded here as a diagnostic — if you
    // never see "· AI" in the status line, this file is not in the build.
    if (!_cameraReady) return 'Starting camera…';
    if (!_motionReady) return 'Get ready…';
    final p = _motion?.lastProbability;
    final pTxt = p == null ? '--' : (p * 100).toStringAsFixed(0);
    return 'Insert the bottle into the slot · AI $pTxt%';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Build
  // ══════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Insert Bottle',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFEF5350)));
    }

    return LayoutBuilder(builder: (_, box) {
      final Size sz = Size(box.maxWidth, box.maxHeight);
      final Offset target = _tracker.toScreenOffset(sz, _sensorOrientation);
      final Offset pivot = Offset(sz.width * 0.50, sz.height * 0.72);

      final double dx = target.dx - pivot.dx;
      final double dy = target.dy - pivot.dy;
      final double ang = (atan2(dx, -dy) * 3.0).clamp(-pi * 0.78, pi * 0.78);

      return Stack(fit: StackFit.expand, children: [
        // ── Camera ─────────────────────────────────────────────────────
        Positioned.fill(child: CameraPreview(_cam!)),

        // ── Subtle vignette overlay ─────────────────────────────────────
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.0,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.35),
                ],
              ),
            ),
          ),
        ),

        // ── White flash on count ────────────────────────────────────────
        if (_showFlash)
          AnimatedBuilder(
            animation: _flashCtrl,
            builder: (_, __) => Opacity(
              opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
              child: Container(color: Colors.white.withOpacity(0.45)),
            ),
          ),

        // ── AR ARROW (professional transparent red) ─────────────────────
        AnimatedBuilder(
          animation: _arCtrl,
          builder: (_, __) => CustomPaint(
            size: sz,
            painter: _ProfessionalArrowPainter(
              pivot: pivot,
              angle: ang,
              animValue: _arCtrl.value,
              hasLock: _lockedAndReady,
              isDetecting: _motionReady && _lockedAndReady,
              target: target,
            ),
          ),
        ),

        // ── Top HUD ─────────────────────────────────────────────────────
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(children: [
                // Session count badge
                ScaleTransition(
                  scale: Tween<double>(begin: 1.0, end: 1.4).animate(
                      CurvedAnimation(
                          parent: _badgeCtrl, curve: Curves.elasticOut)),
                  child: _HudBadge(
                    icon: '🍾',
                    value: '$_sessionCount',
                    highlight: _sessionCount > 0,
                  ),
                ),

                const Spacer(),

                // Countdown
                _HudBadge(
                  icon: '⏱',
                  value: '$_remaining',
                  highlight: _remaining <= 5,
                  dangerColor: true,
                ),
              ]),
            ),
          ),
        ),

        // ── Hint pill when no lock ──────────────────────────────────────
        if (!_tracker.hasLock)
          Positioned(
            top: 120,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.center_focus_weak,
                      color: Colors.white.withOpacity(0.70), size: 15),
                  const SizedBox(width: 7),
                  Text('Aim at the bin slot',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.70),
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ),
          ),

        // ── AR Floating score popups ────────────────────────────────────
        for (final s in List<_FloatingScore>.from(_scores))
          Positioned(
            left: s.origin.dx - 55,
            top: s.origin.dy + s.yOffset - 24,
            width: 110,
            child: Opacity(
              opacity: s.opacity.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: s.scale,
                child: Text(
                  s.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Color(0xFFEF5350), blurRadius: 18),
                      Shadow(color: Colors.black, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // ── Status label ────────────────────────────────────────────────
        Positioned(
          bottom: 96,
          left: 0,
          right: 0,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(_statusText,
                  key: ValueKey(_statusText),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                  )),
            ),
          ),
        ),

        // ── Bottom instruction card ─────────────────────────────────────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  color: Colors.black.withOpacity(0.58),
                  child: const Text(
                    'Arrow tip points at the bin slot.\nInsert the bottle — detected automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white70, fontSize: 13, height: 1.5),
                  ),
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
// _HudBadge — small pill for count and countdown
// ══════════════════════════════════════════════════════════════════════════════
class _HudBadge extends StatelessWidget {
  const _HudBadge({
    required this.icon,
    required this.value,
    this.highlight = false,
    this.dangerColor = false,
  });
  final String icon;
  final String value;
  final bool highlight;
  final bool dangerColor;

  @override
  Widget build(BuildContext context) {
    final Color accent = dangerColor && highlight
        ? Colors.redAccent
        : highlight
            ? const Color(0xFFEF5350)
            : Colors.white70;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.60),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight
              ? accent.withOpacity(0.60)
              : Colors.white.withOpacity(0.12),
          width: 1.2,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(icon, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 6),
        Text(value,
            style: TextStyle(
              color: accent,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            )),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// _ProfessionalArrowPainter
//
// DESIGN LANGUAGE:
//   • 20% red, semi-transparent — arrow is clearly visible but doesn't
//     obstruct the camera feed behind it
//   • Curved Bézier body — pivots at bottom-center, tip tracks the bin slot
//   • Inner highlight + edge glow — gives the arrow depth and a 3D feel
//   • Pulsing opacity on detection — signals bottle is being counted
//   • Rotating dashed reticle at the target — professional AR crosshair
//   • Clean, minimal — no over-engineered effects
//
// COLOR STATES:
//   No lock   → #EF5350 red, 18% opacity  (very faint, guiding)
//   Locked    → #EF5350 red, 58% opacity  (clear, confident)
//   Detecting → #EF5350 red, 90% opacity  (bright, urgent)
// ══════════════════════════════════════════════════════════════════════════════
class _ProfessionalArrowPainter extends CustomPainter {
  const _ProfessionalArrowPainter({
    required this.pivot,
    required this.angle,
    required this.animValue,
    required this.hasLock,
    required this.isDetecting,
    required this.target,
  });

  final Offset pivot;
  final double angle;
  final double animValue;
  final bool hasLock;
  final bool isDetecting;
  final Offset target;

  // Base red color — all arrow elements use this with varying opacity
  static const Color _red = Color(0xFFEF5350);
  static const Color _redLight = Color(0xFFFF8A80);
  static const Color _redDark = Color(0xFFB71C1C);

  // Opacity levels per state
  double get _baseOpacity {
    if (isDetecting) return 0.90;
    if (hasLock) return 0.58;
    return 0.20; // no lock — very faint
  }

  // Pulsing factor for detecting state
  double get _detectPulse =>
      isDetecting ? 0.5 + sin(animValue * pi * 5) * 0.5 : 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final double o = _baseOpacity + _detectPulse * 0.10;

    // ── Bézier: pivot (tail) → ctrl → target (head) ─────────────────────
    final Offset ctrl = Offset(
      pivot.dx + sin(angle) * 55,
      pivot.dy - cos(angle) * 55,
    );

    Offset bez(double t) {
      final double m = 1 - t;
      return Offset(
        m * m * pivot.dx + 2 * m * t * ctrl.dx + t * t * target.dx,
        m * m * pivot.dy + 2 * m * t * ctrl.dy + t * t * target.dy,
      );
    }

    Offset bezTan(double t) {
      final double m = 1 - t;
      return Offset(
        2 * m * (ctrl.dx - pivot.dx) + 2 * t * (target.dx - ctrl.dx),
        2 * m * (ctrl.dy - pivot.dy) + 2 * t * (target.dy - ctrl.dy),
      );
    }

    const double bodyEnd = 0.82;

    // Build body path
    final Path body = Path()..moveTo(pivot.dx, pivot.dy);
    for (int i = 1; i <= 48; i++) {
      body.lineTo(bez((i / 48) * bodyEnd).dx, bez((i / 48) * bodyEnd).dy);
    }

    // ── 1. Soft outer glow (very subtle depth) ───────────────────────────
    canvas.drawPath(
        body,
        Paint()
          ..color = _red.withOpacity(0.08 * o)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 24
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));

    // ── 2. Dark core underside ────────────────────────────────────────────
    canvas.drawPath(
        body,
        Paint()
          ..color = _redDark.withOpacity(0.55 * o)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round);

    // ── 3. Main red body — 20% transparent ───────────────────────────────
    canvas.drawPath(
        body,
        Paint()
          ..color = _red.withOpacity(0.75 * o)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round);

    // ── 4. Bright left-edge highlight (makes it look 3D) ─────────────────
    final Path hl = Path()..moveTo(pivot.dx, pivot.dy);
    for (int i = 1; i <= 48; i++) {
      final double t = (i / 48) * bodyEnd;
      final Offset pt = bez(t);
      final Offset tn = bezTan(t);
      final double tl = tn.distance;
      if (tl < 0.001) continue;
      final Offset n = Offset(-tn.dy / tl, tn.dx / tl);
      hl.lineTo(pt.dx + n.dx * 2.5, pt.dy + n.dy * 2.5);
    }
    canvas.drawPath(
        hl,
        Paint()
          ..color = _redLight.withOpacity(0.45 * o)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round);

    // ── 5. Energy pulse when detecting ───────────────────────────────────
    if (isDetecting || hasLock) {
      final double pEnd = animValue * bodyEnd;
      final double pStart = (animValue - 0.16).clamp(0.0, 1.0) * bodyEnd;
      if (pEnd > pStart) {
        final Path pulse = Path();
        bool first = true;
        for (int i = 0; i <= 55; i++) {
          final double t = (i / 55) * bodyEnd;
          if (t < pStart || t > pEnd) continue;
          final Offset p = bez(t);
          if (first) {
            pulse.moveTo(p.dx, p.dy);
            first = false;
          } else
            pulse.lineTo(p.dx, p.dy);
        }
        if (!first) {
          canvas.drawPath(
              pulse,
              Paint()
                ..color =
                    Colors.white.withOpacity(isDetecting ? 0.70 * o : 0.30 * o)
                ..style = PaintingStyle.stroke
                ..strokeWidth = isDetecting ? 5 : 3
                ..strokeCap = StrokeCap.round
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
        }
      }
    }

    // ── 6. 3D arrowhead cone ─────────────────────────────────────────────
    _drawHead(canvas, bez, bezTan, o);

    // ── 7. Target reticle at slot ────────────────────────────────────────
    _drawReticle(canvas, o);
  }

  void _drawHead(
    Canvas canvas,
    Offset Function(double) bez,
    Offset Function(double) bezTan,
    double o,
  ) {
    const double bodyEnd = 0.82;
    const double len = 28.0;
    const double hw = 16.0;

    final Offset tan = bezTan(bodyEnd);
    final double tl = tan.distance;
    if (tl < 0.001) return;

    final Offset fwd = tan / tl;
    final Offset left = Offset(-fwd.dy, fwd.dx);
    final Offset base = target - fwd * len;
    final Offset lp = base + left * hw;
    final Offset rp = base - left * hw;

    // Depth shadow offset
    final Offset dOff = Offset(fwd.dy * 4, -fwd.dx * 4);

    // Shadow back face
    canvas.drawPath(
        Path()
          ..moveTo(lp.dx + dOff.dx, lp.dy + dOff.dy)
          ..lineTo(rp.dx + dOff.dx, rp.dy + dOff.dy)
          ..lineTo(target.dx + dOff.dx, target.dy + dOff.dy)
          ..close(),
        Paint()..color = _redDark.withOpacity(0.55 * o));

    // Soft glow
    canvas.drawPath(
        Path()
          ..moveTo(lp.dx, lp.dy)
          ..lineTo(rp.dx, rp.dy)
          ..lineTo(target.dx, target.dy)
          ..close(),
        Paint()
          ..color = _red.withOpacity(0.14 * o)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));

    // Main red face
    canvas.drawPath(
        Path()
          ..moveTo(lp.dx, lp.dy)
          ..lineTo(rp.dx, rp.dy)
          ..lineTo(target.dx, target.dy)
          ..close(),
        Paint()..color = _red.withOpacity(0.88 * o));

    // Left highlight sliver
    canvas.drawPath(
        Path()
          ..moveTo(lp.dx, lp.dy)
          ..lineTo(target.dx, target.dy)
          ..lineTo(lp.dx + left.dx * 4, lp.dy + left.dy * 4)
          ..close(),
        Paint()..color = _redLight.withOpacity(0.38 * o));
  }

  void _drawReticle(Canvas canvas, double o) {
    final double pulse = isDetecting
        ? 0.5 + sin(animValue * pi * 5) * 0.5
        : hasLock
            ? 0.5 + sin(animValue * pi * 2) * 0.3
            : 0.25;

    final double r = 20.0 + pulse * 8;

    // Outer soft glow when locked
    if (hasLock) {
      canvas.drawCircle(
          target,
          r + 10,
          Paint()
            ..color = _red.withOpacity(0.10 * o)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }

    // Rotating arc segments (AR dashes)
    final double rot = animValue * pi * 2;
    for (int i = 0; i < 6; i++) {
      final double sa = rot + (i / 6) * pi * 2;
      canvas.drawArc(
          Rect.fromCircle(center: target, radius: r),
          sa,
          pi * 2 / 6 * 0.55,
          false,
          Paint()
            ..color = _red.withOpacity((0.65 + pulse * 0.35) * o)
            ..style = PaintingStyle.stroke
            ..strokeWidth = hasLock ? 2.8 : 1.6
            ..strokeCap = StrokeCap.round);
    }

    // Inner ring
    if (hasLock) {
      canvas.drawCircle(
          target,
          r * 0.48,
          Paint()
            ..color = _red.withOpacity(0.28 * o)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4);
    }

    // Center dot
    canvas.drawCircle(target, hasLock ? 4.5 : 2.8,
        Paint()..color = _red.withOpacity(0.90 * o));

    // Crosshair lines
    final double arm = hasLock ? 12.0 : 8.0;
    const double gap = 6.0;
    final Paint cp = Paint()
      ..color = _red.withOpacity(0.75 * o)
      ..strokeWidth = hasLock ? 1.8 : 1.3
      ..strokeCap = StrokeCap.round;
    final double cx = target.dx, cy = target.dy;
    canvas.drawLine(Offset(cx, cy - gap), Offset(cx, cy - gap - arm), cp);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + gap + arm), cp);
    canvas.drawLine(Offset(cx - gap, cy), Offset(cx - gap - arm, cy), cp);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + gap + arm, cy), cp);

    // Status label
    if (hasLock) {
      final String lbl = isDetecting ? 'INSERTING…' : 'SLOT';
      final tp = TextPainter(
        text: TextSpan(
            text: lbl,
            style: TextStyle(
              color: _red.withOpacity(0.88 * o),
              fontSize: isDetecting ? 11 : 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              shadows: const [Shadow(color: Colors.black, blurRadius: 5)],
            )),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy + r + 8));
    }
  }

  @override
  bool shouldRepaint(_ProfessionalArrowPainter old) =>
      old.pivot != pivot ||
      old.angle != angle ||
      old.animValue != animValue ||
      old.hasLock != hasLock ||
      old.isDetecting != isDetecting ||
      old.target != target;
}
