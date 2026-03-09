import 'package:camera/camera.dart';

/// Simple frame-difference detection in a fixed "arrow" region.
/// Compares current frame to initial reference; if difference exceeds threshold,
/// considers the arrow "disappeared" (bottle inserted / occlusion).
class ArrowDetectionImpl {
  ArrowDetectionImpl({required void Function() onArrowDisappeared})
      : _onArrowDisappeared = onArrowDisappeared;

  final void Function() _onArrowDisappeared;

  List<int>? _referencePixels;
  bool _triggered = false;
  static const int _sampleStep = 8;
  static const double _differenceThreshold = 0.35;

  void processImage(CameraImage image) {
    if (_triggered) return;
    try {
      final pixels = _extractRegionLuminance(image);
      if (pixels == null || pixels.isEmpty) return;
      if (_referencePixels == null) {
        _referencePixels = pixels;
        return;
      }
      final diff = _computeDifference(_referencePixels!, pixels);
      if (diff >= _differenceThreshold) {
        _triggered = true;
        _onArrowDisappeared();
      }
    } catch (_) {}
  }

  /// Sample center region of image (Y plane for YUV).
  List<int>? _extractRegionLuminance(CameraImage image) {
    final plane = image.planes.first;
    if (plane.bytesPerRow == 0) return null;
    final w = image.width;
    final h = image.height;
    final left = (w * 0.35).round();
    final top = (h * 0.35).round();
    final rw = (w * 0.3).round().clamp(1, w - left);
    final rh = (h * 0.25).round().clamp(1, h - top);
    final List<int> out = [];
    for (var y = top; y < top + rh && y < h; y += _sampleStep) {
      for (var x = left; x < left + rw && x < w; x += _sampleStep) {
        final offset = y * plane.bytesPerRow + x;
        if (offset < plane.bytes.length) {
          out.add(plane.bytes[offset] & 0xff);
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  double _computeDifference(List<int> a, List<int> b) {
    if (a.length != b.length) return 0;
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / (a.length * 255);
  }

  void dispose() {
    _referencePixels = null;
    _triggered = true;
  }
}
