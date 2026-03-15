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
    required this.countdown,
    required this.disabled,
  });

  final CameraController controller;
  final VoidCallback onInsertDetected;
  final int countdown;
  final bool disabled;

  @override
  State<ArrowRegionOverlay> createState() => _ArrowRegionOverlayState();
}

class _ArrowRegionOverlayState extends State<ArrowRegionOverlay> {
  ArrowDetectionImpl? _detector;
  bool _disposed = false;
  bool _streamStarted = false;

  @override
  void initState() {
    super.initState();
    _startDetection();
  }

  Future<void> _startDetection() async {
    if (_disposed) return;

    _detector = ArrowDetectionImpl(
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
          color: widget.disabled ? Colors.grey : Colors.green,
          width: 4,
        ),
        borderRadius: BorderRadius.circular(12),
        color: Colors.transparent,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Arrow icon pointing down — this is what gets occluded by the bottle
            Icon(
              Icons.arrow_downward,
              color: widget.disabled ? Colors.grey : Colors.white,
              size: 36,
              shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
            ),
            const SizedBox(height: 6),
            Text(
              widget.disabled ? 'Detected!' : 'Hide and show icon',
              style: TextStyle(
                color: widget.disabled ? Colors.grey : Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}