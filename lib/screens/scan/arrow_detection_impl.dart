import 'dart:io';
import 'package:camera/camera.dart';

/// Robust frame-difference detection supporting both Android (YUV420) and iOS (BGRA8888).
/// - Skips warmup frames before setting reference to avoid dark/uninitialized frames.
/// - Debounces trigger to avoid false positives from single noisy frames.
/// - Handles variable bytesPerRow safely on all devices.
class ArrowDetectionImpl {
  ArrowDetectionImpl({
    required void Function() onInsertDetected,
    required void Function(bool isReady) onReadyChanged,
    required double regionLeft,
    required double regionTop,
    required double regionWidth,
    required double regionHeight,
  })  : _onInsertDetected = onInsertDetected,
        _onReadyChanged = onReadyChanged,
        _regionLeft = regionLeft,
        _regionTop = regionTop,
        _regionWidth = regionWidth,
        _regionHeight = regionHeight;

  final void Function() _onInsertDetected;
  final void Function(bool isReady) _onReadyChanged;
  final double _regionLeft;
  final double _regionTop;
  final double _regionWidth;
  final double _regionHeight;

  List<int>? _referencePixels;
  bool _triggered = false;
  bool _disposed = false;

  /// Number of frames to skip before capturing the reference frame.
  /// Prevents capturing a dark/uninitialized frame on camera startup.
  static const int _warmupFrames = 10;
  int _frameCount = 0;

  /// Consecutive frame counters used for readiness and insertion checks.
  static const int _consecutiveRequired = 3;
  int _readyCount = 0;
  int _unreadyCount = 0;
  bool _isReady = false;
  int _insertCount = 0;

  static const int _sampleStep = 6;

  /// Readiness threshold: bottle appears in the guide before insertion.
  static const double _readyThreshold = 0.18;
  /// Drop threshold after ready: insertion typically darkens the region.
  static const double _insertDarkeningThreshold = 0.12;
  static const double _readyLostThreshold = 0.10;

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
        _readyCount = 0;
        _insertCount = 0;
        return;
      }

      final diff = _computeDifference(_referencePixels!, pixels);

      // Stage 1: bottle aligned in front of the outline.
      if (!_isReady) {
        if (diff >= _readyThreshold) {
          _readyCount++;
          if (_readyCount >= _consecutiveRequired) {
            _isReady = true;
            _onReadyChanged(true);
            // Re-baseline on the ready pose so insertion is detected as next change.
            _referencePixels = List<int>.from(pixels);
            _insertCount = 0;
          }
        } else {
          _readyCount = 0;
          // Slowly adapt to ambient lighting changes while scene is stable.
          if (diff <= _readyLostThreshold) {
            _blendReference(_referencePixels!, pixels);
          }
        }
        return;
      }

      // If user moves away too much, clear ready state and ask to align again.
      if (diff >= _readyThreshold * 1.6) {
        _unreadyCount++;
        if (_unreadyCount >= _consecutiveRequired + 1) {
          _isReady = false;
          _onReadyChanged(false);
          _referencePixels = List<int>.from(pixels);
          _readyCount = 0;
          _insertCount = 0;
          _unreadyCount = 0;
          return;
        }
      } else {
        _unreadyCount = 0;
      }

      // Stage 2: after ready, detect insertion as region darkening.
      final lumaDrop = _computeLumaDrop(_referencePixels!, pixels);
      if (lumaDrop >= _insertDarkeningThreshold) {
        _insertCount++;
        if (_insertCount >= _consecutiveRequired) {
          _triggered = true;
          _onInsertDetected();
          return;
        }
      } else {
        _insertCount = 0;

        // Keep adapting if scene is mostly unchanged.
        if (diff <= _readyLostThreshold) {
          _blendReference(_referencePixels!, pixels);
        } else {
          _referencePixels = List<int>.from(pixels);
        }
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
    final safeLeft = _regionLeft.clamp(0.0, 0.95);
    final safeTop = _regionTop.clamp(0.0, 0.95);
    final safeWidth = _regionWidth.clamp(0.05, 1.0 - safeLeft);
    final safeHeight = _regionHeight.clamp(0.05, 1.0 - safeTop);

    final left = (w * safeLeft).round();
    final top = (h * safeTop).round();
    final rw = (w * safeWidth).round().clamp(1, w - left);
    final rh = (h * safeHeight).round().clamp(1, h - top);

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

  double _computeLumaDrop(List<int> reference, List<int> current) {
    if (reference.length != current.length || reference.isEmpty) return 0;
    var refSum = 0;
    var currentSum = 0;
    for (var i = 0; i < reference.length; i++) {
      refSum += reference[i];
      currentSum += current[i];
    }
    final refMean = refSum / reference.length;
    final currentMean = currentSum / current.length;
    return (refMean - currentMean) / 255.0;
  }

  void _blendReference(List<int> reference, List<int> current) {
    if (reference.length != current.length) return;
    const alpha = 0.08;
    for (var i = 0; i < reference.length; i++) {
      reference[i] = (reference[i] * (1 - alpha) + current[i] * alpha).round();
    }
  }

  void dispose() {
    _disposed = true;
    _triggered = true;
    _referencePixels = null;
    _readyCount = 0;
    _insertCount = 0;
    _isReady = false;
  }
}