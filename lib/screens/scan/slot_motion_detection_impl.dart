import 'dart:io';
import 'package:camera/camera.dart';

enum _InsertPhase { idle, topSeen, midSeen }

class _LumaSample {
  const _LumaSample({
    required this.pixels,
    required this.rows,
    required this.cols,
  });

  final List<int> pixels;
  final int rows;
  final int cols;
}

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

  _LumaSample? _previousSample;
  bool _triggered = false;
  bool _disposed = false;
  bool _readyNotified = false;
  bool _armed = false;

  static const int _warmupFrames = 8;
  static const int _calmConsecutiveRequired = 3;
  static const int _armCalmFramesRequired = 4;
  static const double _motionThreshold = 0.05;
  static const double _readyThreshold = 0.025;
  static const double _bandMotionThreshold = 0.07;
  static const double _strongDiffThreshold = 0.10;
  static const int _phaseTimeoutFrames = 9;
  static const int _sampleStep = 5;
  static const double _diffSmoothingAlpha = 0.35;

  int _frameCount = 0;
  int _calmCount = 0;
  double _smoothedDiff = 0;
  _InsertPhase _phase = _InsertPhase.idle;
  int _phaseStartedAtFrame = 0;

  void processImage(CameraImage image) {
    if (_triggered || _disposed) return;

    try {
      _frameCount++;

      final sample = _extractLuminance(image);
      if (sample == null || sample.pixels.isEmpty) return;

      if (_frameCount <= _warmupFrames) {
        _previousSample = sample;
        return;
      }

      if (_previousSample == null ||
          _previousSample!.pixels.length != sample.pixels.length ||
          _previousSample!.rows != sample.rows ||
          _previousSample!.cols != sample.cols) {
        _previousSample = sample;
        _calmCount = 0;
        _armed = false;
        _phase = _InsertPhase.idle;
        _notifyReady(false);
        return;
      }

      final previous = _previousSample!;
      final diff = _computeDifference(previous.pixels, sample.pixels);
        _smoothedDiff = _smoothedDiff == 0
          ? diff
          : (_smoothedDiff * (1 - _diffSmoothingAlpha)) + (diff * _diffSmoothingAlpha);

        final isMotion = _smoothedDiff >= _motionThreshold;
        final isCalm = _smoothedDiff <= _readyThreshold;
      final topDiff = _computeBandDifference(previous, sample, 0, 0.34);
      final midDiff = _computeBandDifference(previous, sample, 0.34, 0.67);
      final bottomDiff = _computeBandDifference(previous, sample, 0.67, 1.0);

      final topActive = topDiff >= _bandMotionThreshold;
      final midActive = midDiff >= _bandMotionThreshold;
      final bottomActive = bottomDiff >= _bandMotionThreshold;

      final bandSpread = [topDiff, midDiff, bottomDiff]
          .reduce((a, b) => a > b ? a : b) -
          [topDiff, midDiff, bottomDiff].reduce((a, b) => a < b ? a : b);
      final looksLikeGlobalShake =
          topActive && midActive && bottomActive && diff >= _strongDiffThreshold && bandSpread < 0.03;

      if (isCalm) {
        _calmCount++;
        if (_calmCount >= _armCalmFramesRequired) {
          _armed = true;
          _notifyReady(true);
        }
      } else {
        _calmCount = 0;
        _notifyReady(false);
      }

      if (_armed && isMotion) {
        if (looksLikeGlobalShake) {
          _phase = _InsertPhase.idle;
          _armed = false;
        } else {
          final phaseAge = _frameCount - _phaseStartedAtFrame;

          switch (_phase) {
            case _InsertPhase.idle:
              if (topActive && !bottomActive) {
                _phase = _InsertPhase.topSeen;
                _phaseStartedAtFrame = _frameCount;
              }
              break;
            case _InsertPhase.topSeen:
              if (phaseAge > _phaseTimeoutFrames) {
                _phase = _InsertPhase.idle;
              } else if (midActive) {
                _phase = _InsertPhase.midSeen;
                _phaseStartedAtFrame = _frameCount;
              } else if (bottomActive && !midActive) {
                _phase = _InsertPhase.idle;
              }
              break;
            case _InsertPhase.midSeen:
              if (phaseAge > _phaseTimeoutFrames) {
                _phase = _InsertPhase.idle;
              } else if (bottomActive) {
                _triggered = true;
                _onMotionDetected();
                return;
              }
              break;
          }
        }
      } else {
        _phase = _InsertPhase.idle;
      }

      _previousSample = sample;
    } catch (_) {
      // Ignore platform-specific image processing failures and keep streaming.
    }
  }

  _LumaSample? _extractLuminance(CameraImage image) {
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

  _LumaSample? _extractYUV(
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
    var rows = 0;
    var cols = 0;

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      var rowCols = 0;
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
        final offset = y * bytesPerRow + x;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
          rowCols++;
        }
      }
      if (rowCols > 0) {
        rows++;
        cols = rowCols;
      }
    }

    if (out.isEmpty || rows == 0 || cols == 0) return null;
    return _LumaSample(pixels: out, rows: rows, cols: cols);
  }

  _LumaSample? _extractBGRA(
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
    var rows = 0;
    var cols = 0;

    for (var y = top; y < top + regionHeight && y < height; y += _sampleStep) {
      var rowCols = 0;
      for (var x = left; x < left + regionWidth && x < width; x += _sampleStep) {
        final offset = y * bytesPerRow + x * 4 + 1;
        if (offset >= 0 && offset < bytes.length) {
          out.add(bytes[offset] & 0xff);
          rowCols++;
        }
      }
      if (rowCols > 0) {
        rows++;
        cols = rowCols;
      }
    }

    if (out.isEmpty || rows == 0 || cols == 0) return null;
    return _LumaSample(pixels: out, rows: rows, cols: cols);
  }

  double _computeDifference(List<int> previous, List<int> current) {
    if (previous.length != current.length || previous.isEmpty) return 0;

    var sum = 0;
    for (var i = 0; i < previous.length; i++) {
      sum += (previous[i] - current[i]).abs();
    }

    return sum / (previous.length * 255.0);
  }

  double _computeBandDifference(
    _LumaSample previous,
    _LumaSample current,
    double startRatio,
    double endRatio,
  ) {
    if (previous.rows != current.rows ||
        previous.cols != current.cols ||
        previous.pixels.length != current.pixels.length ||
        previous.rows <= 0 ||
        previous.cols <= 0) {
      return 0;
    }

    final startRow = (previous.rows * startRatio).floor().clamp(0, previous.rows - 1);
    final endRowExclusive = (previous.rows * endRatio).ceil().clamp(startRow + 1, previous.rows);

    var sum = 0;
    var count = 0;

    for (var row = startRow; row < endRowExclusive; row++) {
      final base = row * previous.cols;
      for (var col = 0; col < previous.cols; col++) {
        final idx = base + col;
        if (idx >= 0 && idx < previous.pixels.length && idx < current.pixels.length) {
          sum += (previous.pixels[idx] - current.pixels[idx]).abs();
          count++;
        }
      }
    }

    if (count == 0) return 0;
    return sum / (count * 255.0);
  }

  void _notifyReady(bool ready) {
    if (_readyNotified == ready) return;
    _readyNotified = ready;
    _onReadyChanged(ready);
  }

  void dispose() {
    _disposed = true;
    _previousSample = null;
  }
}