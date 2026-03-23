import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

// COCO label index for "bottle" = 44 (0-indexed, including background at 0)
// Reference: https://tech.amikelive.com/node-718/what-object-categories-labels-are-in-coco-dataset/
const int _bottleClassIndex = 44;

// Minimum confidence to accept a TFLite detection.
const double _minConfidence = 0.55;

class TfliteBottleResult {
  final bool isBottle;
  final double confidence;
  final String label;

  const TfliteBottleResult({
    required this.isBottle,
    required this.confidence,
    required this.label,
  });
}

class BottleTfliteService {
  Interpreter? _interpreter;
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> init() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/ssd_mobilenet.tflite',
      );
      _ready = true;
      debugPrint('✅ TFLite model loaded');
    } catch (e) {
      _ready = false;
      debugPrint('❌ TFLite model failed to load: $e');
      debugPrint('   Make sure ssd_mobilenet.tflite is in assets/models/');
    }
  }

  Future<TfliteBottleResult> detectFromFilePath(String path) async {
    if (!_ready || _interpreter == null) {
      debugPrint('⚠️ TFLite not ready — blocking frame');
      return const TfliteBottleResult(
        isBottle: false,
        confidence: 0,
        label: 'Model not ready',
      );
    }

    try {
      final bytes = await File(path).readAsBytes();
      final rawImage = img.decodeImage(bytes);

      if (rawImage == null) {
        debugPrint('⚠️ TFLite: could not decode image');
        return const TfliteBottleResult(
          isBottle: false,
          confidence: 0,
          label: 'Decode failed',
        );
      }

      return _runDetection(rawImage);
    } catch (e) {
      debugPrint('⚠️ TFLite error: $e');
      // Always return false on error — never silently pass through
      return const TfliteBottleResult(
        isBottle: false,
        confidence: 0,
        label: 'Error',
      );
    }
  }

  TfliteBottleResult _runDetection(img.Image source) {
    // SSD MobileNet expects 300×300 RGB uint8 input
    final resized = img.copyResize(source, width: 300, height: 300);

    final input = List.generate(
      1,
      (_) => List.generate(
        300,
        (y) => List.generate(300, (x) {
          final pixel = resized.getPixel(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        }),
      ),
    );

    // SSD MobileNet outputs:
    //   0 → boxes    [1, 10, 4]
    //   1 → classes  [1, 10]
    //   2 → scores   [1, 10]
    //   3 → count    [1]
    final outputBoxes =
        List.generate(1, (_) => List.generate(10, (_) => List.filled(4, 0.0)));
    final outputClasses = List.generate(1, (_) => List.filled(10, 0.0));
    final outputScores = List.generate(1, (_) => List.filled(10, 0.0));
    final outputCount = List.filled(1, 0.0);

    _interpreter!.runForMultipleInputs(
      [input],
      {0: outputBoxes, 1: outputClasses, 2: outputScores, 3: outputCount},
    );

    final count = outputCount[0].toInt().clamp(0, 10);
    double bestScore = 0.0;

    for (int i = 0; i < count; i++) {
      final score = outputScores[0][i];
      final classId = outputClasses[0][i].toInt();

      debugPrint(
        '🔍 TFLite[$i]: class=$classId score=${(score * 100).toStringAsFixed(1)}%'
        '${classId == _bottleClassIndex ? " ← BOTTLE" : ""}',
      );

      if (classId == _bottleClassIndex && score > bestScore) {
        bestScore = score;
      }
    }

    if (bestScore >= _minConfidence) {
      debugPrint('✅ TFLite: bottle at ${(bestScore * 100).toStringAsFixed(1)}%');
      return TfliteBottleResult(
        isBottle: true,
        confidence: bestScore,
        label: 'bottle (${(bestScore * 100).toStringAsFixed(0)}%)',
      );
    }

    debugPrint(
      '❌ TFLite: no bottle — best score was ${(bestScore * 100).toStringAsFixed(1)}%',
    );
    return TfliteBottleResult(
      isBottle: false,
      confidence: bestScore,
      label: 'No bottle detected',
    );
  }

  void dispose() {
    _interpreter?.close();
    _ready = false;
  }
}
