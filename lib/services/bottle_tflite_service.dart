import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

// ── Bottle class indices ──────────────────────────────────────────────────────
// We check 43, 44, AND 45 because different model downloads use different
// indexing depending on whether background is included as class 0.
//
// Check the debug logs — look for the line:
//   "🔍 TOP DETECTION: class=XX score=YY%"
// when pointing at a bottle. That XX is your bottle class index.
const Set<int> _bottleClassIndices = {43, 44, 45};

// ── Confidence threshold ──────────────────────────────────────────────────────
// Quantized SSD MobileNet scores real bottles at 0.25–0.55 in normal lighting.
const double _minConfidence = 0.25;

// ─────────────────────────────────────────────────────────────────────────────

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

class BottleCondition {
  final String status;
  final double confidence;

  const BottleCondition({required this.status, required this.confidence});
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
      debugPrint('❌ TFLite load failed: $e');
    }
  }

  Future<TfliteBottleResult> detectFromFilePath(String path) async {
    if (!_ready || _interpreter == null) {
      return const TfliteBottleResult(
        isBottle: false, confidence: 0, label: 'Model not ready',
      );
    }

    try {
      final bytes = await File(path).readAsBytes();
      final rawImage = img.decodeImage(bytes);
      if (rawImage == null) {
        return const TfliteBottleResult(
          isBottle: false, confidence: 0, label: 'Decode failed',
        );
      }
      return _runDetection(rawImage);
    } catch (e) {
      debugPrint('⚠️ TFLite error: $e');
      return const TfliteBottleResult(
        isBottle: false, confidence: 0, label: 'Error',
      );
    }
  }

  TfliteBottleResult _runDetection(img.Image source) {
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

    final outputBoxes =
        List.generate(1, (_) => List.generate(10, (_) => List.filled(4, 0.0)));
    final outputClasses = List.generate(1, (_) => List.filled(10, 0.0));
    final outputScores  = List.generate(1, (_) => List.filled(10, 0.0));
    final outputCount   = List.filled(1, 0.0);

    _interpreter!.runForMultipleInputs(
      [input],
      {0: outputBoxes, 1: outputClasses, 2: outputScores, 3: outputCount},
    );

    final count = outputCount[0].toInt().clamp(0, 10);

    double bestBottleScore = 0.0;

    // Track the single TOP detection across ALL classes for debugging
    double topScore = 0.0;
    int    topClass = -1;

    debugPrint('──────── TFLite raw detections ($count) ────────');

    for (int i = 0; i < count; i++) {
      final score = outputScores[0][i];
      final classId = outputClasses[0][i].toInt();
      final isBottle = _bottleClassIndices.contains(classId);

      debugPrint(
        '  [$i] class=$classId  '
        'score=${(score * 100).toStringAsFixed(1)}%'
        '${isBottle ? "  ← BOTTLE ✅" : ""}',
      );

      if (score > topScore) {
        topScore = score;
        topClass = classId;
      }

      if (isBottle && score > bestBottleScore) {
        bestBottleScore = score;
      }
    }

    // ── CRITICAL DEBUG LINE ───────────────────────────────────────────────
    // Point the camera at a bottle and look for this line in your logs.
    // The class number shown here is the REAL bottle class your model uses.
    debugPrint(
      '🔍 TOP DETECTION: class=$topClass  '
      'score=${(topScore * 100).toStringAsFixed(1)}%  '
      '← This is what the model sees most confidently',
    );
    debugPrint(
      '🍾 BOTTLE score: ${(bestBottleScore * 100).toStringAsFixed(1)}%  '
      '(checking classes: $_bottleClassIndices)',
    );

    if (bestBottleScore >= _minConfidence) {
      debugPrint('✅ BOTTLE CONFIRMED at ${(bestBottleScore * 100).toStringAsFixed(1)}%');
      return TfliteBottleResult(
        isBottle: true,
        confidence: bestBottleScore,
        label: 'Bottle ${(bestBottleScore * 100).toStringAsFixed(0)}%',
      );
    }

    debugPrint(
      '❌ Not detected. Best bottle score=${(bestBottleScore * 100).toStringAsFixed(1)}%  '
      'Need ${(_minConfidence * 100).toStringAsFixed(0)}%',
    );

    return TfliteBottleResult(
      isBottle: false,
      confidence: bestBottleScore,
      label: 'Not a bottle',
    );
  }

  void dispose() {
    _interpreter?.close();
    _ready = false;
  }
}
