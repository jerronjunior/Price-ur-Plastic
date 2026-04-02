import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'slot_motion_detection_impl.dart';

/// Overlay that keeps the camera stream alive and watches the bin opening slot.
/// When movement passes through the slot region, it calls [onMotionDetected].
class SlotMotionOverlay extends StatefulWidget {
  const SlotMotionOverlay({
    super.key,
    required this.controller,
    required this.onMotionDetected,
    required this.onReadyChanged,
    required this.disabled,
    required this.regionLeft,
    required this.regionTop,
    required this.regionWidth,
    required this.regionHeight,
  });

  final CameraController controller;
  final VoidCallback onMotionDetected;
  final ValueChanged<bool> onReadyChanged;
  final bool disabled;
  final double regionLeft;
  final double regionTop;
  final double regionWidth;
  final double regionHeight;

  @override
  State<SlotMotionOverlay> createState() => _SlotMotionOverlayState();
}

class _SlotMotionOverlayState extends State<SlotMotionOverlay> {
  SlotMotionDetectionImpl? _detector;
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

    _detector = SlotMotionDetectionImpl(
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
      onMotionDetected: () {
        if (!_disposed && !widget.disabled) {
          widget.onMotionDetected();
        }
      },
    );

    if (!widget.controller.value.isInitialized) return;
    if (widget.controller.value.isStreamingImages) return;

    try {
      await widget.controller.startImageStream(_onImage);
      if (mounted) {
        setState(() => _streamStarted = true);
      }
    } catch (e) {
      debugPrint('SlotMotionOverlay: Failed to start image stream: $e');
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

    if (_streamStarted && widget.controller.value.isInitialized) {
      try {
        if (widget.controller.value.isStreamingImages) {
          widget.controller.stopImageStream();
        }
      } catch (e) {
        debugPrint('SlotMotionOverlay: Error stopping image stream: $e');
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
            : Colors.black.withValues(alpha: 0.06),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _SlotGuidePainter(
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
                child: const Icon(Icons.motion_photos_on, color: Colors.white, size: 18),
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
                        ? 'Ready - pass bottle through the slot'
                        : 'Watch the bin opening slot',
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

class _SlotGuidePainter extends CustomPainter {
  const _SlotGuidePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final openingWidth = size.width * 0.58;
    final openingHeight = size.height * 0.22;
    final centerX = size.width / 2;
    final centerY = size.height * 0.28;

    final slotRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, centerY),
        width: openingWidth,
        height: openingHeight,
      ),
      const Radius.circular(16),
    );

    canvas.drawRRect(slotRect, paint);

    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(centerX - openingWidth * 0.25, centerY),
      Offset(centerX + openingWidth * 0.25, centerY),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SlotGuidePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}