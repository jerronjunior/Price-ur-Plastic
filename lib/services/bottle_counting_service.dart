import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter/foundation.dart';

class _ImageProcessData {
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int width;
  final int height;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  _ImageProcessData({
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.width,
    required this.height,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });
}

List<List<List<List<int>>>>? _preprocessImageInIsolate(_ImageProcessData data) {
  try {
    final width = data.width;
    final height = data.height;
    final yPlane = data.yPlane;
    final uPlane = data.uPlane;
    final vPlane = data.vPlane;
    final uvPixelStride = data.uvPixelStride;

    final rgbImage = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int uvx = (x / 2).floor();
        final int uvy = (y / 2).floor();
        final int uvPixelIndex = uvy * data.uvRowStride + uvx * uvPixelStride;

        final int yIndex = y * data.yRowStride + x;
        final int yValue = yPlane[yIndex];
        final int uValue = uPlane[uvPixelIndex];
        final int vValue = vPlane[uvPixelIndex];

        final int r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
        final int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).clamp(0, 255).toInt();
        final int b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();

        rgbImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    final resized = img.copyResize(
      rgbImage,
      width: 300,
      height: 300,
      interpolation: img.Interpolation.linear,
    );

    final List<List<List<List<int>>>> tensorData = List.generate(1, (_) {
      return List.generate(300, (y) {
        return List.generate(300, (x) {
          final pixel = resized.getPixelSafe(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        });
      });
    });

    return tensorData;
  } catch (e) {
    return null;
  }
}

/// Represents a detected bottle with its bounding box and confidence.
class DetectedBottle {
  const DetectedBottle({
    required this.confidence,
    required this.rect, // [x1, y1, x2, y2] normalized 0-1
    required this.label,
  });

  final double confidence;
  final List<double> rect;
  final String label;

  double get centerX => (rect[0] + rect[2]) / 2;
  double get centerY => (rect[1] + rect[3]) / 2;
  double get width => rect[2] - rect[0];
  double get height => rect[3] - rect[1];
}

/// Real-time bottle detection using SSD MobileNet tflite model.
class BottleCountingService {
  static const String _modelPath = 'assets/models/ssd_mobilenet.tflite';
  static const double _confidenceThreshold = 0.5;

  Interpreter? _interpreter;
  bool _isInitialized = false;

  // For tracking consecutive detections
  List<DetectedBottle> _lastDetections = [];

  /// Initialize the tflite model.
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _interpreter = await Interpreter.fromAsset(_modelPath);
      _isInitialized = true;
      print('✅ Bottle Counting Service initialized');
      return true;
    } catch (e) {
      print('❌ Error initializing BottleCountingService: $e');
      _isInitialized = false;
      return false;
    }
  }

  /// Detect bottles in a camera frame.
  /// Returns list of detected bottles sorted by confidence (highest first).
  Future<List<DetectedBottle>> detectBottlesInFrame(CameraImage image) async {
    if (!_isInitialized || _interpreter == null) return [];

    try {
      if (image.planes.length < 3) return [];
      
      final data = _ImageProcessData(
        yPlane: image.planes[0].bytes,
        uPlane: image.planes[1].bytes,
        vPlane: image.planes[2].bytes,
        width: image.width,
        height: image.height,
        yRowStride: image.planes[0].bytesPerRow,
        uvRowStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
      );

      // Convert camera image to input format for tflite using isolate
      final inputImage = await compute(_preprocessImageInIsolate, data);
      if (inputImage == null) return [];

      // Run inference
      final outputBoxes = List.generate(
        1,
        (_) => List.generate(10, (_) => List.filled(4, 0.0)),
      );
      final outputClasses = List.generate(
        1,
        (_) => List.filled(10, 0.0),
      );
      final outputScores = List.generate(
        1,
        (_) => List.filled(10, 0.0),
      );
      final outputCount = List.filled(1, 0.0);

      final outputs = <int, Object>{
        0: outputBoxes,
        1: outputClasses,
        2: outputScores,
        3: outputCount,
      };

      _interpreter!.runForMultipleInputs([inputImage], outputs);

      // Parse detections
      final detections = _parseDetections(outputs, image.width, image.height);

      // Apply smoothing across frames
      _lastDetections = detections;

      return detections;
    } catch (e) {
      print('Error detecting bottles: $e');
      return [];
    }
  }

  // Preprocessing moved to isolate above

  /// Parse tflite SSD output format.
  /// Typical output: [detection_boxes, detection_scores, detection_classes, num_detections]
  List<DetectedBottle> _parseDetections(
    Map<int, Object> outputs,
    int frameWidth,
    int frameHeight,
  ) {
    final detections = <DetectedBottle>[];

    try {
      if (outputs.isEmpty) return detections;

      final boxesOutput = outputs[0];
      final scoresOutput = outputs[2];

      if (boxesOutput is! List || scoresOutput is! List) {
        return detections;
      }

      final firstBoxesBatch = boxesOutput.isNotEmpty ? boxesOutput.first : null;
      final firstScoresBatch = scoresOutput.isNotEmpty ? scoresOutput.first : null;

      if (firstBoxesBatch is! List || firstScoresBatch is! List) {
        return detections;
      }

      final detectionCount = firstBoxesBatch.length < firstScoresBatch.length
          ? firstBoxesBatch.length
          : firstScoresBatch.length;

      // Process each detection.
      for (int i = 0; i < detectionCount; i++) {
        final boxes = firstBoxesBatch[i];
        final score = firstScoresBatch[i];

        if (boxes is! List || boxes.length < 4 || score is! num) continue;

        final confidence = score.toDouble();

        // Filter by confidence threshold
        if (confidence < _confidenceThreshold) continue;

        // Extract bounding box [y1, x1, y2, x2] (normalized)
        final double y1 = (boxes[0] as num).toDouble().clamp(0.0, 1.0);
        final double x1 = (boxes[1] as num).toDouble().clamp(0.0, 1.0);
        final double y2 = (boxes[2] as num).toDouble().clamp(0.0, 1.0);
        final double x2 = (boxes[3] as num).toDouble().clamp(0.0, 1.0);

        // Swap y,x to x,y format [x1, y1, x2, y2]
        detections.add(
          DetectedBottle(
            confidence: confidence,
            rect: [x1, y1, x2, y2],
            label: 'Bottle',
          ),
        );
      }

      // Sort by confidence descending
      detections.sort((a, b) => b.confidence.compareTo(a.confidence));

      return detections;
    } catch (e) {
      print('Error parsing detections: $e');
      return detections;
    }
  }

  /// Get smoothed bottle count across recent frames.
  int getSmoothBottleCount() {
    return _lastDetections.length;
  }

  /// Dispose resources.
  void dispose() {
    _interpreter?.close();
    _isInitialized = false;
  }

  /// Detect bottles from JPEG bytes (e.g., taken via CameraController.takePicture()).
  Future<List<DetectedBottle>> detectBottlesFromJpeg(Uint8List jpegBytes) async {
    if (!_isInitialized || _interpreter == null) return [];
    try {
      final decoded = img.decodeImage(jpegBytes);
      if (decoded == null) return [];

      final resized = img.copyResize(
        decoded,
        width: 300,
        height: 300,
        interpolation: img.Interpolation.linear,
      );

      final List<List<List<List<int>>>> tensorData =
          List.generate(1, (_) {
        return List.generate(300, (y) {
          return List.generate(300, (x) {
            final pixel = resized.getPixelSafe(x, y);
            return [pixel.r as int, pixel.g as int, pixel.b as int];
          });
        });
      });

      final outputBoxes = List.generate(
        1,
        (_) => List.generate(10, (_) => List.filled(4, 0.0)),
      );
      final outputClasses = List.generate(
        1,
        (_) => List.filled(10, 0.0),
      );
      final outputScores = List.generate(
        1,
        (_) => List.filled(10, 0.0),
      );
      final outputCount = List.filled(1, 0.0);

      final outputs = <int, Object>{
        0: outputBoxes,
        1: outputClasses,
        2: outputScores,
        3: outputCount,
      };

      _interpreter!.runForMultipleInputs([tensorData], outputs);

      // Here we don't have original frame dimensions; treat as 1:1
      final detections = _parseDetections(outputs, resized.width, resized.height);
      _lastDetections = detections;
      return detections;
    } catch (e) {
      print('Error detecting from jpeg: $e');
      return [];
    }
  }
}
