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
  with WidgetsBindingObserver {
  CameraController? _cam;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _detected = false;

  final _FlapEngine _engine = _FlapEngine();

  bool _calibrating = false;
  int _calibrationFrames = 0;
  static const int _calibrationFrameCount = 25;

  Timer? _timeoutTimer;
  late int _remainingSeconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;
    _startTimeout();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
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
      _remainingSeconds--;
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
          if (mounted) {
            setState(() {
              _calibrating = false;
              _calibrationFrames = 0;
            });
          }
        }
        return;
      }

      final counted = _engine.processFrame(image);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildCamera(),
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

        return Stack(
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
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _calibrating
                        ? 'Preparing camera...'
                        : _engine.state == _FlapState.open
                            ? 'Counting...'
                            : 'Waiting for insertion...',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
