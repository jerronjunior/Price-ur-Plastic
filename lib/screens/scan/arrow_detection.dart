import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'arrow_detection_impl.dart';

/// Overlay showing the "arrow region" and running frame-difference detection.
/// When pixel change in region exceeds threshold, calls [onArrowDisappeared].
class ArrowRegionOverlay extends StatefulWidget {
  const ArrowRegionOverlay({
    super.key,
    required this.controller,
    required this.onArrowDisappeared,
    required this.countdown,
    required this.disabled,
  });

  final CameraController controller;
  final VoidCallback onArrowDisappeared;
  final int countdown;
  final bool disabled;

  @override
  State<ArrowRegionOverlay> createState() => _ArrowRegionOverlayState();
}

class _ArrowRegionOverlayState extends State<ArrowRegionOverlay> {
  ArrowDetectionImpl? _detector;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _detector = ArrowDetectionImpl(
      onArrowDisappeared: () {
        if (!_disposed && !widget.disabled) {
          widget.onArrowDisappeared();
        }
      },
    );
    widget.controller.startImageStream(_onImage);
  }

  void _onImage(CameraImage image) {
    _detector?.processImage(image);
  }

  @override
  void dispose() {
    _disposed = true;
    widget.controller.stopImageStream();
    _detector?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.green, width: 4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Text(
          'Insert bottle here',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            shadows: [Shadow(color: Colors.black, blurRadius: 4)],
          ),
        ),
      ),
    );
  }
}
