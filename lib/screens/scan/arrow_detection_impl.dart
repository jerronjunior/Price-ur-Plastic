import 'dart:io';
import 'package:camera/camera.dart';

enum _OcclusionState { idle, hidden }

/// Robust frame-difference detection supporting both Android (YUV420) and iOS (BGRA8888).
/// - Skips warmup frames before setting reference to avoid dark/uninitialized frames.
/// - Triggers insertion when arrow is hidden long enough, or hidden then visible again.
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
  _OcclusionState _occlusionState = _OcclusionState.idle;

  /// Number of frames to skip before capturing the reference frame.
  /// Prevents capturing a dark/uninitialized frame on camera startup.
  static const int _warmupFrames = 10;
  int _frameCount = 0;

  /// Hidden state must hold for a few frames to filter out noise.
  static const int _hideConsecutiveRequired = 2;
  int _hideCount = 0;

  /// If arrow remains hidden for this many frames, confirm insertion directly.
  static const int _minHiddenHoldFrames = 8;

  /// After hidden, arrow must be visible again for a few frames to confirm insert.
  static const int _recoveryConsecutiveRequired = 2;
  int _recoveryCount = 0;

  /// Hidden phase timeout in frames (~1.5s at around 30 FPS).
  static const int _maxHiddenFrames = 45;
  int _hiddenSinceFrame = 0;

  static const int _sampleStep = 6;

  /// Luminance drop threshold: arrow region becomes dark when bottle occludes it.
  /// Balanced profile: slightly more sensitive to real arrow occlusion.
  static const double _hideDropThreshold = 0.065;
  /// Recovery threshold: arrow visible again after occlusion.
  static const double _recoverDropThreshold = 0.04;
  /// Stable-scene threshold for gradual reference adaptation.
  static const double _stableThreshold = 0.04;

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
        _occlusionState = _OcclusionState.idle;
        _hideCount = 0;
        _recoveryCount = 0;
        return;
      }

      final diff = _computeDifference(_referencePixels!, pixels);
      final lumaDrop = _computeLumaDrop(_referencePixels!, pixels);
      final bottleHideDetected = lumaDrop >= _hideDropThreshold;
      final arrowVisibleAgain = lumaDrop <= _recoverDropThreshold;

      if (_occlusionState == _OcclusionState.idle) {
        if (bottleHideDetected) {
          _hideCount++;
          if (_hideCount >= _hideConsecutiveRequired) {
            _occlusionState = _OcclusionState.hidden;
            _hiddenSinceFrame = _frameCount;
            _recoveryCount = 0;
          }
        } else {
          _hideCount = 0;
          if (diff <= _stableThreshold) {
            _blendReference(_referencePixels!, pixels);
          }
        }
      } else {
        final hiddenFor = _frameCount - _hiddenSinceFrame;

        // Common real flow: arrow stays hidden while bottle passes in front.
        if (hiddenFor >= _minHiddenHoldFrames) {
          _triggered = true;
          _onInsertDetected();
          return;
        }

        if (hiddenFor > _maxHiddenFrames) {
          // Timeout: reset and reacquire baseline to avoid stale hidden state.
          _occlusionState = _OcclusionState.idle;
          _hideCount = 0;
          _recoveryCount = 0;
          _referencePixels = List<int>.from(pixels);
          _onReadyChanged(false);
          return;
        }

        if (arrowVisibleAgain) {
          _recoveryCount++;
          if (_recoveryCount >= _recoveryConsecutiveRequired) {
            _triggered = true;
            _onInsertDetected();
            return;
          }
        } else {
          _recoveryCount = 0;
        }
      }

      // Keep callback active for compatibility, even though outline UI is hidden.
      _onReadyChanged(_occlusionState == _OcclusionState.idle && !bottleHideDetected);
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
    _occlusionState = _OcclusionState.idle;
    _hideCount = 0;
    _recoveryCount = 0;
  }
}