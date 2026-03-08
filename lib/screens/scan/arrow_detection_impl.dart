import 'package:camera/camera.dart';
import 'dart:math' as math;

/// Enhanced image processing for bottle detection in arrow region.
/// Uses multiple techniques: frame differencing, edge detection, variance analysis.
/// When significant change detected, considers bottle inserted.
class ArrowDetectionImpl {
  ArrowDetectionImpl({required void Function() onArrowDisappeared})
      : _onArrowDisappeared = onArrowDisappeared;

  final void Function() _onArrowDisappeared;

  List<int>? _referencePixels;
  List<int>? _referenceEdges;
  double? _referenceVariance;
  int _frameCount = 0;
  bool _triggered = false;
  int _regionCols = 0; // Track sampled width for edge detection
  
  static const int _sampleStep = 6; // Smaller step for better sampling
  static const double _differenceThreshold = 0.25; // More sensitive
  static const double _edgeThreshold = 0.30; // Edge difference threshold
  static const double _varianceThreshold = 0.40; // Variance change threshold
  static const int _stabilizationFrames = 3; // Wait for stable reference

  void processImage(CameraImage image) {
    if (_triggered) return;
    try {
      _frameCount++;
      
      // Extract luminance data from the region
      final pixels = _extractRegionLuminance(image);
      if (pixels == null || pixels.isEmpty) return;
      
      // Wait for stabilization before setting reference
      if (_referencePixels == null) {
        if (_frameCount >= _stabilizationFrames) {
          _referencePixels = pixels;
          _referenceEdges = _computeEdges(pixels);
          _referenceVariance = _computeVariance(pixels);
        }
        return;
      }
      
      // Multi-technique detection
      final luminanceDiff = _computeDifference(_referencePixels!, pixels);
      final currentEdges = _computeEdges(pixels);
      final edgeDiff = _referenceEdges != null 
          ? _computeDifference(_referenceEdges!, currentEdges)
          : 0.0;
      final currentVariance = _computeVariance(pixels);
      final varianceDiff = _referenceVariance != null
          ? (currentVariance - _referenceVariance!).abs() / (_referenceVariance! + 0.001)
          : 0.0;
      
      // Trigger if any detection method exceeds threshold
      if (luminanceDiff >= _differenceThreshold ||
          edgeDiff >= _edgeThreshold ||
          varianceDiff >= _varianceThreshold) {
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
    final left = (w * 0.15).round();
    final top = (h * 0.2).round();
    final rw = (w * 0.7).round().clamp(1, w - left);
    final rh = (h * 0.6).round().clamp(1, h - top);
    
    // Calculate columns for edge detection
    _regionCols = (rw / _sampleStep).ceil();
    
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

  /// Compute simple edge detection using Sobel-like operator
  /// Detects significant gradients in the image
  List<int> _computeEdges(List<int> pixels) {
    if (pixels.length < 9 || _regionCols == 0) return pixels;
    
    final cols = _regionCols;
    final List<int> edges = [];
    
    for (var i = 0; i < pixels.length; i++) {
      if (i < cols || i >= pixels.length - cols || i % cols == 0 || i % cols == cols - 1) {
        edges.add(0); // Border pixels
        continue;
      }
      
      // Simple Sobel approximation (horizontal + vertical gradients)
      final leftIdx = i - 1;
      final rightIdx = i + 1;
      final topIdx = i - cols;
      final bottomIdx = i + cols;
      
      if (rightIdx < pixels.length && bottomIdx < pixels.length) {
        final gx = (pixels[rightIdx] - pixels[leftIdx]).abs();
        final gy = (pixels[bottomIdx] - pixels[topIdx]).abs();
        final magnitude = math.sqrt(gx * gx + gy * gy).round();
        edges.add(magnitude.clamp(0, 255));
      } else {
        edges.add(0);
      }
    }
    
    return edges;
  }

  /// Calculate variance (measure of pixel distribution/texture)
  /// High variance = detailed texture, low variance = uniform/occluded
  double _computeVariance(List<int> pixels) {
    if (pixels.isEmpty) return 0;
    
    // Calculate mean
    var sum = 0;
    for (var pixel in pixels) {
      sum += pixel;
    }
    final mean = sum / pixels.length;
    
    // Calculate variance
    var varianceSum = 0.0;
    for (var pixel in pixels) {
      final diff = pixel - mean;
      varianceSum += diff * diff;
    }
    
    return math.sqrt(varianceSum / pixels.length);
  }

  void dispose() {
    _referencePixels = null;
    _referenceEdges = null;
    _referenceVariance = null;
    _triggered = true;
  }
}
