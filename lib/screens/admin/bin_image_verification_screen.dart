import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// BinImageVerificationScreen
///
/// Allows admin users to verify bin images using the camera.
/// Similar to InsertionDetectorScreen but optimized for capturing bin photos.
/// Uses frame analysis to detect when a stable, clear image is captured.
class BinImageVerificationScreen extends StatefulWidget {
  const BinImageVerificationScreen({
    super.key,
    required this.onImageCaptured,
    required this.onBack,
    this.timeoutSeconds = 30,
  });

  final void Function(XFile image) onImageCaptured;
  final VoidCallback onBack;
  final int timeoutSeconds;

  @override
  State<BinImageVerificationScreen> createState() =>
      _BinImageVerificationScreenState();
}

class _BinImageVerificationScreenState
    extends State<BinImageVerificationScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  CameraDescription? _camDesc;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _captured = false;

  // ── Frame quality detection ────────────────────────────────────────────────
  int _stableQualityFrames = 0;
  static const int _requiredStableFrames = 12;
  double _lastBrightness = 0.0;

  // ── Timeout ────────────────────────────────────────────────────────────────
  Timer? _timeoutTimer;
  late int _remainingSeconds;

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _flashCtrl;
  bool _showFlash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remainingSeconds = widget.timeoutSeconds;

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

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
    _pulseCtrl.dispose();
    _flashCtrl.dispose();
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
      if (!mounted || _captured) return;
      setState(() => _remainingSeconds--);
      if (_remainingSeconds <= 0) {
        _timeoutTimer?.cancel();
        widget.onBack();
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
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cam!.initialize();
      try {
        final min = await _cam!.getMinZoomLevel();
        final max = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel((min <= 1.0 && max >= 1.0) ? 1.0 : min);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _cameraReady = true;
      });

      await _cam!.startImageStream(_onFrame);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Camera error: $e')),
      );
    }
  }

  // Analyze frame quality (brightness, motion stability)
  double _analyzeFrameQuality(CameraImage image) {
    final Uint8List yPlane = image.planes[0].bytes;
    double sumBrightness = 0;
    int sampleCount = 0;

    // Sample every 16th pixel for efficiency
    for (int i = 0; i < yPlane.length; i += 16) {
      sumBrightness += yPlane[i];
      sampleCount++;
    }

    final double avgBrightness =
        sampleCount > 0 ? sumBrightness / sampleCount : 128;

    // Check if brightness is stable (not too dark, not too bright)
    if (avgBrightness < 50 || avgBrightness > 220) {
      _stableQualityFrames = 0;
      return 0;
    }

    // Check for motion stability (brightness delta)
    final double brightnessDelta = (_lastBrightness - avgBrightness).abs();
    _lastBrightness = avgBrightness;

    if (brightnessDelta > 15) {
      _stableQualityFrames = 0;
      return 0;
    }

    return 1.0;
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _captured) return;
    _processingFrame = true;

    try {
      final quality = _analyzeFrameQuality(image);
      if (quality > 0) {
        _stableQualityFrames++;
      } else {
        _stableQualityFrames = 0;
      }

      if (_stableQualityFrames >= _requiredStableFrames) {
        _captureImage();
      }

      if (mounted) setState(() {});
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _captureImage() async {
    if (_captured || _cam == null) return;
    _captured = true;
    _timeoutTimer?.cancel();

    try {
      final XFile image = await _cam!.takePicture();
      _showFlash = true;
      _flashCtrl.forward(from: 0).then((_) {
        if (mounted) setState(() => _showFlash = false);
      });

      // Stop image stream and fully dispose camera before navigating/pop
      try {
        await _cam?.stopImageStream();
      } catch (_) {}

      try {
        await _cam?.dispose();
      } catch (_) {}

      // Return the captured image to the caller now that the camera is cleaned up.
      if (mounted) widget.onImageCaptured(image);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error capturing image: $e')),
      );
      _captured = false;
      _startTimeout();
    }
  }

  String get _statusText {
    if (_stableQualityFrames < _requiredStableFrames) {
      final percent = ((_stableQualityFrames / _requiredStableFrames) * 100)
          .toStringAsFixed(0);
      return 'Position bin clearly... ($percent%)';
    }
    return 'Capturing...';
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
        title: const Text(
          'Capture Bin Image',
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

    return LayoutBuilder(
      builder: (ctx, box) {
        final Size size = Size(box.maxWidth, box.maxHeight);
        final bool isReady = _stableQualityFrames >= _requiredStableFrames;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            Positioned.fill(child: CameraPreview(_cam!)),
            Container(color: Colors.black.withValues(alpha: 0.08)),

            // Flash on capture
            if (_showFlash)
              AnimatedBuilder(
                animation: _flashCtrl,
                builder: (_, __) => Opacity(
                  opacity: (1.0 - _flashCtrl.value).clamp(0.0, 1.0),
                  child: Container(color: Colors.white.withValues(alpha: 0.40)),
                ),
              ),

            // Capture frame overlay
            Positioned.fill(
              child: CustomPaint(
                painter: _CaptureFramePainter(
                  isReady: isReady,
                  progress: _stableQualityFrames / _requiredStableFrames,
                ),
              ),
            ),

            // Countdown timer
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

            // Status text with progress
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _stableQualityFrames / _requiredStableFrames,
                        minHeight: 4,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isReady
                              ? const Color(0xFF4CAF50)
                              : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Pulse animation when ready
            if (isReady)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) {
                    final scale = 0.95 + (_pulseCtrl.value * 0.05);
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Color.fromARGB(
                              (255 * (1 - _pulseCtrl.value)).toInt(),
                              76,
                              175,
                              80,
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

            // Instructions
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Position your phone to capture a clear image of the entire bin. Keep steady until auto-capture completes.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
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

// ══════════════════════════════════════════════════════════════════════════════
// Custom painter for capture frame overlay
// ══════════════════════════════════════════════════════════════════════════════
class _CaptureFramePainter extends CustomPainter {
  _CaptureFramePainter({
    required this.isReady,
    required this.progress,
  });

  final bool isReady;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const double frameInset = 40;
    const double cornerLen = 30;

    final Rect frameRect = Rect.fromLTWH(
      frameInset,
      (size.height * 0.15),
      size.width - (frameInset * 2),
      (size.height * 0.6),
    );

    // Frame border
    final Paint framePaint = Paint()
      ..color = isReady ? const Color(0xFF4CAF50) : Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRect(frameRect, framePaint);

    // Corner markers
    final Paint cornerPaint = Paint()
      ..color = isReady ? const Color(0xFF4CAF50) : Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    // Top-left
    canvas.drawLine(
      frameRect.topLeft,
      frameRect.topLeft + Offset(cornerLen, 0),
      cornerPaint,
    );
    canvas.drawLine(
      frameRect.topLeft,
      frameRect.topLeft + Offset(0, cornerLen),
      cornerPaint,
    );

    // Top-right
    canvas.drawLine(
      frameRect.topRight,
      frameRect.topRight + Offset(-cornerLen, 0),
      cornerPaint,
    );
    canvas.drawLine(
      frameRect.topRight,
      frameRect.topRight + Offset(0, cornerLen),
      cornerPaint,
    );

    // Bottom-left
    canvas.drawLine(
      frameRect.bottomLeft,
      frameRect.bottomLeft + Offset(cornerLen, 0),
      cornerPaint,
    );
    canvas.drawLine(
      frameRect.bottomLeft,
      frameRect.bottomLeft + Offset(0, -cornerLen),
      cornerPaint,
    );

    // Bottom-right
    canvas.drawLine(
      frameRect.bottomRight,
      frameRect.bottomRight + Offset(-cornerLen, 0),
      cornerPaint,
    );
    canvas.drawLine(
      frameRect.bottomRight,
      frameRect.bottomRight + Offset(0, -cornerLen),
      cornerPaint,
    );

    // Semi-transparent overlay outside frame
    final Paint overlayPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.4);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, frameRect.top),
      overlayPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, frameRect.bottom, size.width, size.height - frameRect.bottom),
      overlayPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, frameRect.top, frameInset, frameRect.height),
      overlayPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width - frameInset, frameRect.top, frameInset, frameRect.height),
      overlayPaint,
    );
  }

  @override
  bool shouldRepaint(_CaptureFramePainter oldDelegate) {
    return oldDelegate.isReady != isReady || oldDelegate.progress != progress;
  }
}
