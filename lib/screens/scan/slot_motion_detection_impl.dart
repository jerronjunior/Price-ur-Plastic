import 'dart:io';
import 'package:camera/camera.dart';

/// Motion-based detector for the bin opening slot.
///
/// It watches a small preview region and fires when a bottle causes a short
/// burst of consistent movement through that slot area.
class SlotMotionDetectionImpl {
  SlotMotionDetectionImpl({
    required void Function() onMotionDetected,
    required void Function(bool isReady) onReadyChanged,
    required double regionLeft,
    required double regionTop,
    required double regionWidth,
    required double regionHeight,
  })  : _onMotionDetected = onMotionDetected,
        _onReadyChanged = onReadyChanged,
        _regionLeft = regionLeft,
        _regionTop = regionTop,
        _regionWidth = regionWidth,
        _regionHeight = regionHeight;

  final void Function() _onMotionDetected;
  final void Function(bool isReady) _onReadyChanged;
  final double _regionLeft;
  final double _regionTop;
  final double _regionWidth;
  final double _regionHeight;

  List<int>? _previousPixels;
  bool _triggered = false;
  bool _disposed = false;
  bool _readyNotified = false;

  static const int _warmupFrames = 8;
  static const int _motionConsecutiveRequired = 2;
  static const int _calmConsecutiveRequired = 2;
  static const double _motionThreshold = 0.06;
  static const double _instantMotionThreshold = 0.115;
  static const double _readyThreshold = 0.025;
  static const int _sampleStep = 5;
  static const double _diffSmoothingAlpha = 0.35;

  int _frameCount = 0;
  int _motionCount = 0;
  int _calmCount = 0;
  double _smoothedDiff = 0;

  void processImage(CameraImage image) {
    if (_triggered || _disposed) return;

    try {
      _frameCount++;

      final pixels = _extractLuminance(image);
      if (pixels == null || pixels.isEmpty) return;

      if (_frameCount <= _warmupFrames) {
        _previousPixels = List<int>.from(pixels);
        return;
      }

      if (_previousPixels == null || _previousPixels!.length != pixels.length) {
        _previousPixels = List<int>.from(pixels);
        _motionCount = 0;
        _calmCount = 0;
        _notifyReady(false);
        return;
      }

        final diff = _computeDifference(_previousPixels!, pixels);
        _smoothedDiff = _smoothedDiff == 0
          ? diff
          : (_smoothedDiff * (1 - _diffSmoothingAlpha)) + (diff * _diffSmoothingAlpha);

        final isFastMotion = diff >= _instantMotionThreshold;
        final isMotion = _smoothedDiff >= _motionThreshold;
        final isCalm = _smoothedDiff <= _readyThreshold;

      if (isMotion) {
        _motionCount++;
        _calmCount = 0;
        _notifyReady(false);

        if (isFastMotion || _motionCount >= _motionConsecutiveRequired) {
          _triggered = true;
          _onMotionDetected();
          return;
        }
      } else {
        _motionCount = 0;

        if (isCalm) {
          _calmCount++;
          if (_calmCount >= _calmConsecutiveRequired) {
            _notifyReady(true);
          }
        } else {
          _calmCount = 0;
          _notifyReady(false);
        }
      }

      _previousPixels = List<int>.from(pixels);
    } catch (_) {
      // Ignore platform-specific image processing failures and keep streaming.
    }
  }

  List<int>? _extractLuminance(CameraImage image) {
    if (image.planes.isEmpty) return null;

    final width = image.width;
    final height = image.height;
    if (width <= 0 || height <= 0) return null;

    final safeLeft = _regionLeft.clamp(0.0, 0.95);
    final safeTop = _regionTop.clamp(0.0, 0.95);
    final safeWidth = _regionWidth.clamp(0.05, 1.0 - safeLeft);
    final safeHeight = _regionHeight.clamp(0.05, 1.0 - safeTop);

    final left = (width * safeLeft).round();
    final top = (height * safeTop).round();
    final regionWidth = (width * safeWidth).round().clamp(1, width - left);
    final regionHeight = (height * safeHeight).round().clamp(1, height - top);

    if (Platform.isIOS) {
      return _extractBGRA(image, left, top, regionWidth, regionHeight, width, height);
    }

    return _extractYUV(image, left, top, regionWidth, regionHeight, width, height);
  }

  List<int>? _extractYUV(
    CameraImage image,
    int left,
    int top,
    int regionWidth,
    int regionHeight,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
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
    int left,
    int top,
    int regionWidth,
    int regionHeight,
    int width,
    int height,
  ) {
    final plane = image.planes[0];
    final bytesPerRow = plane.bytesPerRow;
    if (bytesPerRow <= 0) return null;

    final bytes = plane.bytes;
    final out = <int>[];

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
        final offset = y * bytesPerRow + x * 4 + 1;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
        }
      }
    }

    return out.isEmpty ? null : out;
  }

  double _computeDifference(List<int> previous, List<int> current) {
    if (previous.length != current.length || previous.isEmpty) return 0;

    var sum = 0;
    for (var i = 0; i < previous.length; i++) {
      sum += (previous[i] - current[i]).abs();
    }

    return sum / (previous.length * 255.0);
  }

  void _notifyReady(bool ready) {
    if (_readyNotified == ready) return;
    _readyNotified = ready;
    _onReadyChanged(ready);
  }

  void dispose() {
    _disposed = true;
    _previousPixels = null;
  }
}