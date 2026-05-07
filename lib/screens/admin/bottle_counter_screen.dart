import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:math' as math;
import 'dart:async';
import '../../services/bottle_counting_service.dart';
import '../../core/theme.dart';

/// Dedicated bottle counter screen with real-time AR detection and 3D particle visualization.
class BottleCounterScreen extends StatefulWidget {
  const BottleCounterScreen({super.key});

  @override
  State<BottleCounterScreen> createState() => _BottleCounterScreenState();
}

class _BottleCounterScreenState extends State<BottleCounterScreen>
    with TickerProviderStateMixin {
  // Camera & detection
  CameraController? _cam;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;

  // Service
  late BottleCountingService _bottleService;

  // State
  int _bottleCount = 0;
  int _maxBottlesDetected = 0;
  List<DetectedBottle> _currentDetections = [];
  bool _isDetecting = false;

  // Animation
  late AnimationController _pulseCtrl;
  late AnimationController _confettiCtrl;
  bool _showConfetti = false;
  int _lastCount = 0;

  // UI
  bool _showBoundingBoxes = true;

  @override
  void initState() {
    super.initState();
    _bottleService = BottleCountingService();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _initializeServices();
  }

  Future<void> _initializeServices() async {
    await _bottleService.initialize();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _showError('No cameras available');
        return;
      }

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

      await _cam!.initialize();

      if (!mounted) return;
      setState(() => _cameraReady = true);

      await _cam!.startImageStream(_onFrame);
    } catch (e) {
      _showError('Camera error: $e');
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || !_isDetecting) return;

    _processingFrame = true;

    _bottleService.detectBottlesInFrame(image).then((detections) {
      if (!mounted) return;

      setState(() {
        _currentDetections = detections;
        _bottleCount = detections.length;
        _maxBottlesDetected = _maxBottlesDetected > _bottleCount
            ? _maxBottlesDetected
            : _bottleCount;

        // Trigger confetti on new max
        if (_bottleCount > _lastCount && _bottleCount > 0) {
          _playConfetti();
        }
        _lastCount = _bottleCount;
      });

      _processingFrame = false;
    }).catchError((e) {
      _processingFrame = false;
    });
  }

  void _playConfetti() {
    _showConfetti = true;
    _confettiCtrl.forward(from: 0).then((_) {
      if (mounted) {
        setState(() => _showConfetti = false);
      }
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppTheme.error,
      ),
    );
  }

  void _resetCounter() {
    setState(() {
      _bottleCount = 0;
      _maxBottlesDetected = 0;
      _lastCount = 0;
      _currentDetections.clear();
    });
  }

  void _toggleDetection() {
    setState(() => _isDetecting = !_isDetecting);
  }

  void _toggleBoundingBoxes() {
    setState(() => _showBoundingBoxes = !_showBoundingBoxes);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _confettiCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    _bottleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Bottle Counter AR',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_showBoundingBoxes ? Icons.visibility : Icons.visibility_off),
            tooltip: 'Toggle detection boxes',
            onPressed: _toggleBoundingBoxes,
          ),
        ],
      ),
      body: _cameraReady && _cam != null && _cam!.value.isInitialized
          ? _buildCameraView()
          : const Center(
              child: CircularProgressIndicator(
                color: AppTheme.primaryGreen,
              ),
            ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildCameraView() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        CameraPreview(_cam!),
        Container(color: Colors.black.withValues(alpha: 0.08)),

        // Detection overlay with bounding boxes
        if (_showBoundingBoxes && _isDetecting)
          _DetectionOverlay(
            detections: _currentDetections,
            cameraWidth: _cam!.value.previewSize?.width ?? 1,
            cameraHeight: _cam!.value.previewSize?.height ?? 1,
          ),

        // Particle effect (confetti-like)
        if (_showConfetti)
          _ParticleEffectLayer(
            animation: _confettiCtrl,
            bottleCount: _bottleCount,
          ),

        // Live counter display (top-right)
        Positioned(
          top: 20,
          right: 20,
          child: _CounterBadge(
            count: _bottleCount,
            maxCount: _maxBottlesDetected,
            isDetecting: _isDetecting,
            animation: _pulseCtrl,
          ),
        ),

        // Status indicator (center-top)
        if (!_isDetecting)
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade700,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pause_circle, color: Colors.white),
                    SizedBox(width: 8),
                    Text(
                      'Detection paused',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Instructions
        Positioned(
          bottom: 120,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _isDetecting
                    ? 'Point at bottles - they will be counted in real-time'
                    : 'Tap START to begin counting',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Stats row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatTile(
                  label: 'Current',
                  value: _bottleCount.toString(),
                  color: AppTheme.primaryGreen,
                ),
                _StatTile(
                  label: 'Max',
                  value: _maxBottlesDetected.toString(),
                  color: AppTheme.primaryBlue,
                ),
                _StatTile(
                  label: 'Status',
                  value: _isDetecting ? 'Active' : 'Paused',
                  color: _isDetecting
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFFF9800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(_isDetecting ? Icons.pause : Icons.play_arrow),
                    label: Text(_isDetecting ? 'PAUSE' : 'START'),
                    onPressed: _toggleDetection,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryGreen,
                      side: const BorderSide(color: AppTheme.primaryGreen),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('RESET'),
                    onPressed: _resetCounter,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Live counter badge showing current and max count with animation.
class _CounterBadge extends StatelessWidget {
  const _CounterBadge({
    required this.count,
    required this.maxCount,
    required this.isDetecting,
    required this.animation,
  });

  final int count;
  final int maxCount;
  final bool isDetecting;
  final AnimationController animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, __) {
        final scale = isDetecting ? 0.95 + (animation.value * 0.1) : 1.0;
        final alpha = isDetecting ? 0.8 + (animation.value * 0.2) : 0.7;

        return Transform.scale(
          scale: scale,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.green.shade700.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.green.shade400.withValues(alpha: 0.6),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withValues(alpha: 0.4),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  count.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
                Text(
                  'bottles',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (maxCount > 0)
                  Text(
                    'Peak: $maxCount',
                    style: TextStyle(
                      color: Colors.yellow.shade200,
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Overlay drawing detected bottle bounding boxes.
class _DetectionOverlay extends StatelessWidget {
  const _DetectionOverlay({
    required this.detections,
    required this.cameraWidth,
    required this.cameraHeight,
  });

  final List<DetectedBottle> detections;
  final double cameraWidth;
  final double cameraHeight;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DetectionPainter(
        detections: detections,
        cameraWidth: cameraWidth,
        cameraHeight: cameraHeight,
      ),
      size: Size.infinite,
    );
  }
}

/// Custom painter for drawing detection boxes.
class _DetectionPainter extends CustomPainter {
  _DetectionPainter({
    required this.detections,
    required this.cameraWidth,
    required this.cameraHeight,
  });

  final List<DetectedBottle> detections;
  final double cameraWidth;
  final double cameraHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / cameraWidth;
    final scaleY = size.height / cameraHeight;

    for (int i = 0; i < detections.length; i++) {
      final detection = detections[i];
      final color = _getColorForConfidence(detection.confidence);

      // Draw bounding box
      final rect = Rect.fromLTWH(
        detection.rect[0] * size.width,
        detection.rect[1] * size.height,
        detection.width * size.width,
        detection.height * size.height,
      );

      // Box outline
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;

      canvas.drawRect(rect, boxPaint);

      // Corner brackets
      const cornerLen = 20.0;
      final cornerPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;

      // Top-left
      canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(cornerLen, 0), cornerPaint);
      canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, cornerLen), cornerPaint);
      // Top-right
      canvas.drawLine(rect.topRight, rect.topRight + const Offset(-cornerLen, 0), cornerPaint);
      canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, cornerLen), cornerPaint);
      // Bottom-left
      canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(cornerLen, 0), cornerPaint);
      canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(0, -cornerLen), cornerPaint);
      // Bottom-right
      canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(-cornerLen, 0), cornerPaint);
      canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(0, -cornerLen), cornerPaint);

      // Label with confidence
      _drawLabel(
        canvas,
        'Bottle #${i + 1}\n${(detection.confidence * 100).toStringAsFixed(0)}%',
        rect.topLeft + const Offset(0, -30),
        color,
      );
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset position, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          position.dx - 4,
          position.dy - 4,
          textPainter.width + 8,
          textPainter.height + 8,
        ),
        const Radius.circular(4),
      ),
      bgPaint,
    );

    textPainter.paint(canvas, position);
  }

  Color _getColorForConfidence(double confidence) {
    if (confidence > 0.8) return Colors.green;
    if (confidence > 0.6) return Colors.yellow;
    return Colors.orange;
  }

  @override
  bool shouldRepaint(_DetectionPainter oldDelegate) =>
      oldDelegate.detections.length != detections.length;
}

/// 3D-like particle effect layer (confetti for new bottles detected).
class _ParticleEffectLayer extends StatelessWidget {
  const _ParticleEffectLayer({
    required this.animation,
    required this.bottleCount,
  });

  final AnimationController animation;
  final int bottleCount;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, __) {
        return CustomPaint(
          painter: _ParticlePainter(
            progress: animation.value,
            particleCount: (bottleCount * 8).clamp(20, 100),
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

/// Custom painter for particle/confetti effects.
class _ParticlePainter extends CustomPainter {
  _ParticlePainter({
    required this.progress,
    required this.particleCount,
  });

  final double progress;
  final int particleCount;

  @override
  void paint(Canvas canvas, Size size) {
    final random = _seededRandom(12345); // For consistent particles

    for (int i = 0; i < particleCount; i++) {
      final angle = (i / particleCount) * 3.14159 * 2;
      final distance = progress * 200;
      final cx = size.width / 2;
      final cy = size.height / 2;

      final px = cx + distance * math.cos(angle);
      final py = cy + distance * math.sin(angle);

      final opacity = (1.0 - progress).clamp(0.0, 1.0);
      final scale = (1.0 - progress * 0.3).clamp(0.3, 1.0);

      final paint = Paint()
        ..color = _getParticleColor(i).withValues(alpha: opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(px, py), 3 * scale, paint);
    }
  }

  Color _getParticleColor(int index) {
    final colors = [
      Colors.green,
      Colors.lightGreen,
      Colors.lime,
      Colors.teal,
      Colors.cyan,
    ];
    return colors[index % colors.length];
  }

  @override
  bool shouldRepaint(_ParticlePainter oldDelegate) => true;
}

/// Simple seeded random for consistent particle effects.
int _seededRandom(int seed) {
  seed = (seed ^ 61) ^ (seed >> 16);
  seed = seed + (seed << 3);
  seed = seed ^ (seed >> 4);
  seed = seed * 0x27d4eb2d;
  return seed ^ (seed >> 15);
}

/// Statistics tile showing label and value.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
