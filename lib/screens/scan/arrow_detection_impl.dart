import 'dart:io';
import 'package:camera/camera.dart';

/// Robust frame-difference detection supporting both Android (YUV420) and iOS (BGRA8888).
/// - Skips warmup frames before setting reference to avoid dark/uninitialized frames.
/// - Debounces trigger to avoid false positives from single noisy frames.
/// - Handles variable bytesPerRow safely on all devices.
class ArrowDetectionImpl {
  ArrowDetectionImpl({required void Function() onArrowDisappeared})
      : _onArrowDisappeared = onArrowDisappeared;

  final void Function() _onArrowDisappeared;

  List<int>? _referencePixels;
  bool _triggered = false;
  bool _disposed = false;

  /// Number of frames to skip before capturing the reference frame.
  /// Prevents capturing a dark/uninitialized frame on camera startup.
  static const int _warmupFrames = 10;
  int _frameCount = 0;

  /// Consecutive frames above threshold required before triggering.
  /// Prevents false positives from a single noisy frame.
  static const int _consecutiveRequired = 3;
  int _consecutiveCount = 0;

  static const int _sampleStep = 6;

  /// Lower threshold = more sensitive. 0.25 works well for arrow occlusion.
  static const double _differenceThreshold = 0.25;

  void processImage(CameraImage image) {
    if (_triggered || _disposed) return;
    try {
      _frameCount++;

      // Skip warmup frames
      if (_frameCount <= _warmupFrames) return;

      final pixels = _extractLuminance(image);
      if (pixels == null || pixels.isEmpty) return;

      // Capture reference frame after warmup
      if (_referencePixels == null) {
        _referencePixels = pixels;
        return;
      }

      // Lengths can differ if image size changes — reset reference
      if (pixels.length != _referencePixels!.length) {
        _referencePixels = pixels;
        _consecutiveCount = 0;
        return;
      }

      final diff = _computeDifference(_referencePixels!, pixels);

      if (diff >= _differenceThreshold) {
        _consecutiveCount++;
        if (_consecutiveCount >= _consecutiveRequired) {
          _triggered = true;
          _onArrowDisappeared();
        }
      } else {
        // Reset consecutive count on a clean frame
        _consecutiveCount = 0;
      }
    } catch (_) {
      // Silently ignore any platform-specific image processing errors
    }
  }

  /// Extract luminance from the center region of the image.
  /// Handles both YUV420 (Android) and BGRA8888 (iOS) formats.
  List<int>? _extractLuminance(CameraImage image) {
    if (image.planes.isEmpty) return null;

    final w = image.width;
    final h = image.height;
    if (w <= 0 || h <= 0) return null;

    // Center region: 30% wide, 25% tall, centered in frame
    final left = (w * 0.35).round();
    final top = (h * 0.35).round();
    final rw = (w * 0.30).round().clamp(1, w - left);
    final rh = (h * 0.25).round().clamp(1, h - top);

    final List<int> out = [];

    if (Platform.isAndroid) {
      // YUV420: luminance is the Y plane (plane 0)
      return _extractYUV(image, left, top, rw, rh, w, h);
    } else if (Platform.isIOS) {
      // BGRA8888: extract green channel as luminance proxy
      return _extractBGRA(image, left, top, rw, rh, w, h);
    }

    // Fallback: try Y plane regardless
    return _extractYUV(image, left, top, rw, rh, w, h);
  }

  List<int>? _extractYUV(
    CameraImage image,
    int left, int top, int rw, int rh, int w, int h,
  ) {
    final plane = image.planes[0]; // Y plane
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final List<int> out = [];

    for (var y = top; y < top + rh && y < h; y += _sampleStep) {
      for (var x = left; x < left + rw && x < w; x += _sampleStep) {
        final offset = y * bytesPerRow + x;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  List<int>? _extractBGRA(
    CameraImage image,
    int left, int top, int rw, int rh, int w, int h,
  ) {
    final plane = image.planes[0]; // Single BGRA plane on iOS
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final List<int> out = [];

    // BGRA layout: 4 bytes per pixel — B=0, G=1, R=2, A=3
    // Use green channel (index 1) as luminance proxy
    for (var y = top; y < top + rh && y < h; y += _sampleStep) {
      for (var x = left; x < left + rw && x < w; x += _sampleStep) {
        final offset = y * bytesPerRow + x * 4 + 1; // Green channel
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  double _computeDifference(List<int> a, List<int> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var sum = 0;
    for (var i = 0; i < a.length; i++) {
      sum += (a[i] - b[i]).abs();
    }
    return sum / (a.length * 255.0);
  }

  void dispose() {
    _disposed = true;
    _triggered = true;
    _referencePixels = null;
  }
}