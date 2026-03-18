import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'arrow_detection_impl.dart';

/// Overlay showing the "arrow region" and running frame-difference detection.
/// When the icon region is hidden and then visible again, calls [onInsertDetected].
///
/// IMPORTANT: This widget manages its own image stream lifecycle.
/// The [controller] must be fully initialized before passing it here,
/// and must NOT already have an active image stream.
class ArrowRegionOverlay extends StatefulWidget {
  const ArrowRegionOverlay({
    super.key,
    required this.controller,
    required this.onInsertDetected,
    required this.onReadyChanged,
    required this.countdown,
    required this.disabled,
    required this.regionLeft,
    required this.regionTop,
    required this.regionWidth,
    required this.regionHeight,
  });

  final CameraController controller;
  final VoidCallback onInsertDetected;
  final ValueChanged<bool> onReadyChanged;
  final int countdown;
  final bool disabled;
  final double regionLeft;
  final double regionTop;
  final double regionWidth;
  final double regionHeight;

  @override
  State<ArrowRegionOverlay> createState() => _ArrowRegionOverlayState();
}

class _ArrowRegionOverlayState extends State<ArrowRegionOverlay> {
  ArrowDetectionImpl? _detector;
  bool _disposed = false;
  bool _streamStarted = false;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _startDetection();
  }

  Future<void> _startDetection() async {
    if (_disposed) return;

    _detector = ArrowDetectionImpl(
      regionLeft: widget.regionLeft,
      regionTop: widget.regionTop,
      regionWidth: widget.regionWidth,
      regionHeight: widget.regionHeight,
      onReadyChanged: (ready) {
        if (_disposed || !mounted) return;
        if (_isReady == ready) return;
        setState(() => _isReady = ready);
        widget.onReadyChanged(ready);
      },
      onInsertDetected: () {
        if (!_disposed && !widget.disabled) {
          widget.onInsertDetected();
        }
      },
    );

    // Guard: only start stream if controller is ready and not already streaming
    if (!widget.controller.value.isInitialized) return;
    if (widget.controller.value.isStreamingImages) return;

    try {
      await widget.controller.startImageStream(_onImage);
      if (mounted) {
        setState(() => _streamStarted = true);
      }
    } catch (e) {
      debugPrint('ArrowRegionOverlay: Failed to start image stream: $e');
    }
  }

  void _onImage(CameraImage image) {
    if (!_disposed) {
      _detector?.processImage(image);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _detector?.dispose();

    // Only stop stream if we started it and it's still running
    if (_streamStarted && widget.controller.value.isInitialized) {
      try {
        if (widget.controller.value.isStreamingImages) {
          widget.controller.stopImageStream();
        }
      } catch (e) {
        debugPrint('ArrowRegionOverlay: Error stopping image stream: $e');
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        border: Border.all(
          color: widget.disabled
              ? Colors.grey
              : _isReady
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
          width: 4,
        ),
        borderRadius: BorderRadius.circular(12),
        color: _isReady
            ? Colors.green.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.08),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _BottleOutlinePainter(
                color: widget.disabled
                    ? Colors.grey
                    : _isReady
                        ? Colors.greenAccent
                        : Colors.white70,
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: AnimatedOpacity(
              opacity: _isReady ? 1 : 0.25,
              duration: const Duration(milliseconds: 250),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _isReady ? Colors.green : Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, color: Colors.white, size: 18),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
              child: Text(
                widget.disabled
                    ? 'Detected!'
                    : _isReady
                        ? 'Ready - insert bottle now'
                        : 'Align bottle inside outline',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.disabled
                      ? Colors.grey
                      : _isReady
                          ? Colors.greenAccent
                          : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottleOutlinePainter extends CustomPainter {
  const _BottleOutlinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final bottleWidth = size.width * 0.42;
    final neckWidth = bottleWidth * 0.40;
    final neckHeight = size.height * 0.16;
    final bodyHeight = size.height * 0.55;
    final startY = size.height * 0.14;
    final centerX = size.width / 2;

    final neckRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, startY + neckHeight / 2),
        width: neckWidth,
        height: neckHeight,
      ),
      const Radius.circular(8),
    );

    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, startY + neckHeight + bodyHeight / 2),
        width: bottleWidth,
        height: bodyHeight,
      ),
      const Radius.circular(20),
    );

    canvas.drawRRect(neckRect, paint);
    canvas.drawRRect(bodyRect, paint);
  }

  @override
  bool shouldRepaint(covariant _BottleOutlinePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}