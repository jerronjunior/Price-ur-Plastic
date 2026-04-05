import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

enum _FlapState {
  idle,
  open,
}

class _FlapEngine {
  Rect zone = const Rect.fromLTRB(0.25, 0.10, 0.75, 0.65);

  double baselineBrightness = 0;
  bool isCalibrated = false;
  double darkThresholdFraction = 0.25;

  _FlapState state = _FlapState.idle;
  double currentBrightness = 0;
  bool lastRejectedBySpoof = false;
  DateTime? _flapOpenTime;

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
    final flapOpen = currentBrightness < darkThreshold;

    switch (state) {
      case _FlapState.idle:
        if (flapOpen) {
          state = _FlapState.open;
          _flapOpenTime = DateTime.now();
        }
        break;
      case _FlapState.open:
        if (!flapOpen) {
          final openMs = _flapOpenTime != null
              ? DateTime.now().difference(_flapOpenTime!).inMilliseconds
              : 0;

          if (openMs > _maxFlapOpenMs) {
            lastRejectedBySpoof = true;
            state = _FlapState.idle;
            _flapOpenTime = null;
            return false;
          }

          lastRejectedBySpoof = false;
          state = _FlapState.idle;
          _flapOpenTime = null;
          _lastCount = DateTime.now();
          return true;
        }

        if (_flapOpenTime != null &&
            DateTime.now().difference(_flapOpenTime!).inMilliseconds > _maxFlapOpenMs) {
          lastRejectedBySpoof = true;
          state = _FlapState.idle;
          _flapOpenTime = null;
        }
        break;
    }

    return false;
  }

  void addCalibrationSample(CameraImage image) {
    final b = _zoneBrightness(image, zone);
    if (baselineBrightness == 0) {
      baselineBrightness = b;
    } else {
      baselineBrightness = baselineBrightness * 0.7 + b * 0.3;
    }
  }

  void finalizeCalibration() {
    isCalibrated = baselineBrightness > 10;
  }

  double _zoneBrightness(CameraImage image, Rect z) {
    final fw = image.width;
    final fh = image.height;
    final Uint8List yPlane = image.planes[0].bytes;

    final x0 = (z.left * fw).toInt().clamp(0, fw - 1);
    final y0 = (z.top * fh).toInt().clamp(0, fh - 1);
    final x1 = (z.right * fw).toInt().clamp(0, fw - 1);
    final y1 = (z.bottom * fh).toInt().clamp(0, fh - 1);

    double sum = 0;
    int count = 0;
    const step = 4;

    for (int py = y0; py < y1; py += step) {
      for (int px = x0; px < x1; px += step) {
        final idx = py * fw + px;
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
    lastRejectedBySpoof = false;
  }
}

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
  State<InsertionDetectorScreen> createState() => _InsertionDetectorScreenState();
}

class _InsertionDetectorScreenState extends State<InsertionDetectorScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _cam;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _detected = false;

  final _FlapEngine _engine = _FlapEngine();

  bool _drawingZone = false;
  Offset? _dragStart;

  bool _calibrating = false;
  int _calibrationFrames = 0;
  static const int _calibrationFrameCount = 25;

  late final AnimationController _pulseCtrl;
  late final AnimationController _countCtrl;
  bool _showCountAnim = false;

  Timer? _timeoutTimer;
  late int _countdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _countCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _countdown = widget.timeoutSeconds;
    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _pulseCtrl.dispose();
    _countCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _cam?.dispose();
    }
    if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _detected) return;
      setState(() => _countdown--);
      if (_countdown <= 0) {
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
      setState(() => _cameraReady = true);
      await _cam!.startImageStream(_onFrame);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Camera error: $e');
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
            _showSnack(
              'Calibrated. Baseline: ${_engine.baselineBrightness.toStringAsFixed(1)}',
            );
          }
        } else if (mounted) {
          setState(() {});
        }
        return;
      }

      final counted = _engine.processFrame(image);
      if (!mounted) return;
      setState(() {});

      if (counted) {
        _detected = true;
        _timeoutTimer?.cancel();
        _showCountAnim = true;
        _countCtrl.forward(from: 0).then((_) {
          if (mounted) setState(() => _showCountAnim = false);
        });
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) widget.onDetected();
        });
      }
    } finally {
      _processingFrame = false;
    }
  }

  void _onDragStart(DragStartDetails d, Size sz) {
    if (!_drawingZone) return;
    _dragStart = Offset(d.localPosition.dx / sz.width, d.localPosition.dy / sz.height);
  }

  void _onDragUpdate(DragUpdateDetails d, Size sz) {
    if (!_drawingZone || _dragStart == null) return;
    final cur = Offset(d.localPosition.dx / sz.width, d.localPosition.dy / sz.height);
    setState(() {
      _engine.zone = Rect.fromPoints(_dragStart!, cur);
      _engine.reset();
      _engine.isCalibrated = false;
      _engine.baselineBrightness = 0;
    });
  }

  void _onDragEnd(DragEndDetails _) {
    if (!_drawingZone) return;
    setState(() => _drawingZone = false);
    _dragStart = null;
    _showSnack('Zone set. Tap Calibrate.');
  }

  void _startCalibration() {
    if (_calibrating) return;
    setState(() {
      _calibrating = true;
      _calibrationFrames = 0;
      _engine.baselineBrightness = 0;
      _engine.isCalibrated = false;
      _engine.reset();
    });
    _showSnack('Keep flap CLOSED while calibrating...');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07100A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildCamera()),
            _buildStatusRow(),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      color: const Color(0xFF0D1A0D),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
            onPressed: widget.onBack,
          ),
          const SizedBox(width: 8),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bin Insertion Check',
                style: TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                'Detecting flap open-close pattern',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              '${_countdown}s',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCamera() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00E676)),
      );
    }

    return LayoutBuilder(
      builder: (ctx, box) {
        final size = Size(box.maxWidth, box.maxHeight);

        return GestureDetector(
          onPanStart: (d) => _onDragStart(d, size),
          onPanUpdate: (d) => _onDragUpdate(d, size),
          onPanEnd: _onDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
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
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => CustomPaint(
                    size: size,
                    painter: _FlapZonePainter(
                      zone: _engine.zone,
                      flapState: _engine.state,
                      isCalibrated: _engine.isCalibrated,
                      inCooldown: _engine.inCooldown,
                      brightness: _engine.currentBrightness,
                      baseline: _engine.baselineBrightness,
                      darkThreshold: _engine.darkThreshold,
                      pulse: _pulseCtrl.value,
                    ),
                  ),
                ),
              ),
              if (_calibrating)
                Positioned(
                  top: 16,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Calibrating flap baseline...',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _calibrationFrames / _calibrationFrameCount,
                            backgroundColor: Colors.white12,
                            color: const Color(0xFF00E676),
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_drawingZone)
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.gesture, color: Colors.white70, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Draw a box around the arrow flap only',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_showCountAnim)
                AnimatedBuilder(
                  animation: _countCtrl,
                  builder: (_, __) {
                    final t = _countCtrl.value;
                    final opacity = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.0, 1.0);
                    return Opacity(
                      opacity: opacity,
                      child: Container(
                        color: const Color(0xFF00E676).withValues(alpha: 0.08),
                        child: Center(
                          child: Transform.scale(
                            scale: (0.5 + t * 0.8).clamp(0.0, 2.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 22),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0D250D).withValues(alpha: 0.95),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: const Color(0xFF00E676), width: 2),
                              ),
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.local_drink, color: Color(0xFF00E676), size: 48),
                                  SizedBox(height: 6),
                                  Text(
                                    '+1 Bottle!',
                                    style: TextStyle(
                                      color: Color(0xFF00E676),
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    'Inserted successfully',
                                    style: TextStyle(color: Colors.white54, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatusRow() {
    final state = _engine.state;
    final calibrated = _engine.isCalibrated;
    final cooldown = _engine.inCooldown;
    final spoof = _engine.lastRejectedBySpoof;

    String statusText;
    Color statusColor;
    IconData statusIcon;

    if (!calibrated && !_calibrating) {
      statusText = 'Not calibrated - tap Calibrate first';
      statusColor = Colors.orange;
      statusIcon = Icons.warning_amber;
    } else if (_calibrating) {
      statusText = 'Calibrating... keep flap closed';
      statusColor = Colors.amber;
      statusIcon = Icons.hourglass_top;
    } else if (cooldown) {
      statusText = 'Bottle counted. Cooldown...';
      statusColor = const Color(0xFF00E676);
      statusIcon = Icons.check_circle;
    } else if (spoof) {
      statusText = 'Flap held too long - not counted';
      statusColor = Colors.redAccent;
      statusIcon = Icons.block;
    } else if (state == _FlapState.open) {
      statusText = 'Flap open - bottle dropping in...';
      statusColor = Colors.orangeAccent;
      statusIcon = Icons.arrow_downward;
    } else {
      final ratio = _engine.baselineBrightness > 0
          ? (_engine.currentBrightness / _engine.baselineBrightness).clamp(0.0, 1.5)
          : 1.0;
      final barStr = ratio < 0.85 ? 'DARK' : 'bright';
      statusText = 'Monitoring flap  $barStr';
      statusColor = Colors.white38;
      statusIcon = Icons.radar;
    }

    return Container(
      color: const Color(0xFF0D1A0D),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 12)),
          ),
          if (calibrated && !_calibrating)
            Text(
              'B:${_engine.currentBrightness.toStringAsFixed(0)}/${_engine.baselineBrightness.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white24, fontSize: 10),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      color: const Color(0xFF07100A),
      child: Column(
        children: [
          Row(
            children: [
              const Text('Sensitivity', style: TextStyle(color: Colors.white38, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: (1 - _engine.darkThresholdFraction) * 100,
                  min: 60,
                  max: 95,
                  divisions: 35,
                  activeColor: const Color(0xFF00E676),
                  inactiveColor: Colors.white12,
                  onChanged: (v) {
                    setState(() {
                      _engine.darkThresholdFraction = 1 - v / 100;
                      _engine.reset();
                    });
                  },
                ),
              ),
              Text(
                '${((1 - _engine.darkThresholdFraction) * 100).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _btn(
                  icon: Icons.crop_free,
                  label: _drawingZone ? 'Drawing...' : 'Set zone',
                  color: const Color(0xFF29B6F6),
                  onTap: () => setState(() {
                    _drawingZone = !_drawingZone;
                    _engine.reset();
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _btn(
                  icon: Icons.adjust,
                  label: _calibrating ? 'Calibrating...' : 'Calibrate',
                  color: const Color(0xFFFFD600),
                  onTap: _startCalibration,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _btn(
                  icon: Icons.refresh,
                  label: 'Reset',
                  color: Colors.redAccent,
                  onTap: () => setState(() {
                    _engine.reset();
                    _engine.isCalibrated = false;
                    _engine.baselineBrightness = 0;
                    _calibrating = false;
                    _calibrationFrames = 0;
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _btn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlapZonePainter extends CustomPainter {
  const _FlapZonePainter({
    required this.zone,
    required this.flapState,
    required this.isCalibrated,
    required this.inCooldown,
    required this.brightness,
    required this.baseline,
    required this.darkThreshold,
    required this.pulse,
  });

  final Rect zone;
  final _FlapState flapState;
  final bool isCalibrated;
  final bool inCooldown;
  final double brightness;
  final double baseline;
  final double darkThreshold;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      zone.left * size.width,
      zone.top * size.height,
      zone.right * size.width,
      zone.bottom * size.height,
    );
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    Color color;
    if (!isCalibrated) {
      color = Colors.orange;
    } else if (inCooldown) {
      color = const Color(0xFF00E676);
    } else if (flapState == _FlapState.open) {
      color = Color.lerp(Colors.orangeAccent, Colors.red, pulse)!;
    } else {
      color = const Color(0xFF00E676);
    }

    final dim = Paint()..color = Colors.black.withValues(alpha: 0.42);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, rect.top), dim);
    canvas.drawRect(Rect.fromLTWH(0, rect.bottom, size.width, size.height - rect.bottom), dim);
    canvas.drawRect(Rect.fromLTWH(0, rect.top, rect.left, rect.height), dim);
    canvas.drawRect(Rect.fromLTWH(rect.right, rect.top, size.width - rect.right, rect.height), dim);

    final border = Paint()
      ..color = color.withValues(alpha: flapState == _FlapState.open ? 0.6 + pulse * 0.4 : 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(rr, border);

    final cp = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    const c = 16.0;
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(c, 0), cp);
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(0, c), cp);
    canvas.drawLine(rect.topRight, rect.topRight.translate(-c, 0), cp);
    canvas.drawLine(rect.topRight, rect.topRight.translate(0, c), cp);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(c, 0), cp);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(0, -c), cp);
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(-c, 0), cp);
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(0, -c), cp);

    if (isCalibrated && baseline > 0) {
      final barW = rect.width - 16;
      final ratio = (brightness / baseline).clamp(0.0, 1.2);
      final barBg = Paint()..color = Colors.white10;
      final barFill = Paint()
        ..color = flapState == _FlapState.open
            ? Colors.redAccent.withValues(alpha: 0.7)
            : const Color(0xFF00E676).withValues(alpha: 0.6);
      final barRect = Rect.fromLTWH(rect.left + 8, rect.bottom - 14, barW, 6);
      final barFillRect = Rect.fromLTWH(
        rect.left + 8,
        rect.bottom - 14,
        barW * ratio.clamp(0.0, 1.0),
        6,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(barRect, const Radius.circular(3)), barBg);
      canvas.drawRRect(RRect.fromRectAndRadius(barFillRect, const Radius.circular(3)), barFill);

      final threshX = rect.left + 8 + barW * (darkThreshold / baseline).clamp(0.0, 1.0);
      final threshPaint = Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.9)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(threshX, rect.bottom - 17), Offset(threshX, rect.bottom - 8), threshPaint);
    }

    if (flapState == _FlapState.open) {
      _drawLabel(canvas, rect, 'Flap open - counting...', color);
    } else if (inCooldown) {
      _drawLabel(canvas, rect, 'Counted', color);
    }
  }

  void _drawLabel(Canvas canvas, Rect rect, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(rect.left + 8, rect.top + 8));
  }

  @override
  bool shouldRepaint(_FlapZonePainter old) {
    return old.flapState != flapState ||
        old.isCalibrated != isCalibrated ||
        old.inCooldown != inCooldown ||
        old.pulse != pulse ||
        old.brightness != brightness ||
        old.zone != zone;
  }
}
