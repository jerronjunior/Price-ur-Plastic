import 'dart:io';
import 'package:camera/camera.dart';

enum _PassState {
  idle,
  entering,
  inside,
  exiting,
}

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
/// 5-filter pipeline adapted for this app:
/// 1) zone filter, 2) motion size, 3) downward direction,
/// 4) entry->inside->exit state machine, 5) cooldown.
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
  bool _disposed = false;
  bool _readyNotified = false;

  static const int _warmupFrames = 8;
  static const int _sampleStep = 2;

  // Filter 2: min changed fraction in zone
  static const double _minChangeFraction = 0.12;
  // Filter 3: downward dominance score threshold
  static const double _minDownwardScore = 0.56;
  // Filter 5: cooldown after each count
  static const int _cooldownMs = 2200;
  // Pixel diff threshold for per-pixel motion map
  static const int _pixelDiffThreshold = 28;
  static const int _bands = 20;

  int _frameCount = 0;
  _PassState _state = _PassState.idle;
  DateTime? _lastCount;
  final List<double> _rowHistory = List<double>.filled(_bands, 0.0);

  double _changedFraction = 0;
  double _downwardScore = 0;

  void processImage(CameraImage image) {
    if (_disposed) return;

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
        _state = _PassState.idle;
        _resetRows();
        _notifyReady(false);
        return;
      }

      final previous = _previousSample!;
      final zoneLen = sample.pixels.length;
      if (zoneLen == 0) {
        _previousSample = sample;
        return;
      }

      if (_inCooldown()) {
        _notifyReady(false);
        _previousSample = sample;
        return;
      }

      final bandMotion = List<double>.filled(_bands, 0.0);
      var totalChanged = 0;

      final zoneW = sample.cols;
      final zoneH = sample.rows;

      for (var i = 0; i < zoneLen; i++) {
        final diff = (sample.pixels[i] - previous.pixels[i]).abs();
        if (diff > _pixelDiffThreshold) {
          totalChanged++;
          final row = i ~/ zoneW;
          final band = ((row / zoneH) * _bands).clamp(0, _bands - 1).toInt();
          bandMotion[band] += 1.0;
        }
      }

      // Filter 2: motion must be significant enough in slot zone.
      _changedFraction = totalChanged / zoneLen;

      if (_changedFraction < _minChangeFraction) {
        final shouldCount = _state == _PassState.inside || _state == _PassState.exiting;
        _state = _PassState.idle;
        _resetRows();
        _notifyReady(true);

        if (shouldCount) {
          _lastCount = DateTime.now();
          _notifyReady(false);
          _onMotionDetected();
          _previousSample = sample;
          return;
        }

        _previousSample = sample;
        return;
      }

      _notifyReady(false);

      // Smooth band motion and compute direction bias.
      final bandMax = bandMotion.reduce((a, b) => a > b ? a : b);
      if (bandMax > 0) {
        for (var b = 0; b < _bands; b++) {
          _rowHistory[b] = _rowHistory[b] * 0.6 + (bandMotion[b] / bandMax) * 0.4;
        }
      }

      var upperSum = 0.0;
      var lowerSum = 0.0;
      for (var b = 0; b < _bands ~/ 2; b++) {
        upperSum += _rowHistory[b];
      }
      for (var b = _bands ~/ 2; b < _bands; b++) {
        lowerSum += _rowHistory[b];
      }

      final total = upperSum + lowerSum;
      _downwardScore = total > 0 ? lowerSum / total : 0;

      // Filter 3: ignore sideways/upward jitter.
      if (_downwardScore < _minDownwardScore) {
        _previousSample = sample;
        return;
      }

      // Filter 4: entry -> inside -> exiting progression.
      double weightedBand = 0;
      double weightSum = 0;
      for (var b = 0; b < _bands; b++) {
        weightedBand += b * bandMotion[b];
        weightSum += bandMotion[b];
      }

      final centroid = weightSum > 0 ? weightedBand / weightSum : 0;
      final relPos = centroid / _bands;

      switch (_state) {
        case _PassState.idle:
          if (relPos < 0.45 && _changedFraction > _minChangeFraction) {
            _state = _PassState.entering;
          }
          break;
        case _PassState.entering:
          if (relPos >= 0.30) {
            _state = _PassState.inside;
          }
          break;
        case _PassState.inside:
          if (relPos > 0.60) {
            _state = _PassState.exiting;
          }
          break;
        case _PassState.exiting:
          // Count on the next low-motion frame.
          break;
      }

      _previousSample = sample;
    } catch (_) {
      // Ignore platform-specific image processing failures and keep streaming.
    }
  }

  bool _inCooldown() {
    final lastCount = _lastCount;
    if (lastCount == null) return false;
    return DateTime.now().difference(lastCount).inMilliseconds < _cooldownMs;
  }

  void _resetRows() {
    for (var i = 0; i < _rowHistory.length; i++) {
      _rowHistory[i] = 0;
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