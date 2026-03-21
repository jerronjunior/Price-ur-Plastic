import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:flutter/foundation.dart';

class BottleRecognitionResult {
  final bool isBottle;
  final double confidence;
  final List<String> matchedLabels;
  final List<String> rawLabels;

  const BottleRecognitionResult({
    required this.isBottle,
    required this.confidence,
    required this.matchedLabels,
    required this.rawLabels,
  });
}

class BottleScanAnalysis {
  final BottleRecognitionResult recognition;
  final BottleCondition condition;

  const BottleScanAnalysis({
    required this.recognition,
    required this.condition,
  });
}

class BottleCondition {
  final String status; // 'dropped', 'non-dropped', 'unknown'
  final double confidence; // 0.0 to 1.0
  final List<String> detectedDamageIndicators; // e.g., ['crack', 'break']
  final List<String> detectedIntactIndicators; // e.g., ['intact', 'whole']
  final List<String> rawLabels; // raw ML Kit labels

  BottleCondition({
    required this.status,
    required this.confidence,
    required this.detectedDamageIndicators,
    required this.detectedIntactIndicators,
    required this.rawLabels,
  });

  @override
  String toString() =>
      'BottleCondition(status: $status, confidence: ${(confidence * 100).toStringAsFixed(1)}%, damage: $detectedDamageIndicators, intact: $detectedIntactIndicators)';
}

class BottleAIService {
  // Keywords indicating there is a bottle in frame.
  static const _bottleKeywords = [
    'bottle',
    'plastic bottle',
    'glass bottle',
    'water bottle',
    'beverage bottle',
    'drink bottle',
    'container',
    'flask',
    'jug',
  ];

  // Keywords indicating bottle damage / dropped state
  static const _damageKeywords = [
    'broken',
    'crack',
    'cracked',
    'shattered',
    'damage',
    'damaged',
    'defect',
    'defective',
    'chip',
    'chipped',
    'dent',
    'dented',
    'fragment',
    'fragments',
    'debris',
    'fracture',
    'fractured',
    'split',
    'splinter',
    'splinters',
    'hole',
    'hole',
    'rupture',
    'ruptured',
    'wound',
    'wounded',
    'scratches',
    'scratched',
    'flawed',
    'flaw',
  ];

  // Keywords indicating bottle is intact / non-dropped
  static const _intactKeywords = [
    'intact',
    'whole',
    'solid',
    'smooth',
    'clean',
    'perfect',
    'pristine',
    'undamaged',
    'unbroken',
    'new',
    'good condition',
    'bottle',
    'plastic bottle',
    'glass bottle',
    'water bottle',
    'beverage bottle',
    'container',
  ];

  final ImageLabeler _imageLabeler;

  BottleAIService({ImageLabeler? imageLabeler})
      : _imageLabeler = imageLabeler ??
            ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.3));

  /// Analyzes bottle condition from an InputImage
  /// Returns BottleCondition with status ('dropped', 'non-dropped', 'unknown')
  Future<BottleCondition> analyzeBottleCondition(InputImage image) async {
    try {
      final labels = await _imageLabeler.processImage(image);
      return _analyzeBottleConditionFromLabels(labels);
    } catch (e) {
      debugPrint('❌ Bottle AI analysis error: $e');
      return BottleCondition(
        status: 'unknown',
        confidence: 0.0,
        detectedDamageIndicators: [],
        detectedIntactIndicators: [],
        rawLabels: [],
      );
    }
  }

  Future<BottleRecognitionResult> recognizeBottle(InputImage image) async {
    try {
      final labels = await _imageLabeler.processImage(image);
      return _recognizeBottleFromLabels(labels);
    } catch (e) {
      debugPrint('❌ Bottle recognition error: $e');
      return const BottleRecognitionResult(
        isBottle: false,
        confidence: 0.0,
        matchedLabels: [],
        rawLabels: [],
      );
    }
  }

  Future<BottleScanAnalysis> analyzeBottle(InputImage image) async {
    try {
      final labels = await _imageLabeler.processImage(image);
      final recognition = _recognizeBottleFromLabels(labels);
      final condition = _analyzeBottleConditionFromLabels(labels);
      return BottleScanAnalysis(recognition: recognition, condition: condition);
    } catch (e) {
      debugPrint('❌ Bottle scan analysis error: $e');
      return BottleScanAnalysis(
        recognition: const BottleRecognitionResult(
          isBottle: false,
          confidence: 0.0,
          matchedLabels: [],
          rawLabels: [],
        ),
        condition: BottleCondition(
          status: 'unknown',
          confidence: 0.0,
          detectedDamageIndicators: const [],
          detectedIntactIndicators: const [],
          rawLabels: const [],
        ),
      );
    }
  }

  BottleRecognitionResult _recognizeBottleFromLabels(List<ImageLabel> labels) {
    final matched = <String>[];
    var bestConfidence = 0.0;

    for (final label in labels) {
      final text = label.label.toLowerCase();
      if (_bottleKeywords.any((kw) => text.contains(kw))) {
        matched.add(label.label);
        if (label.confidence > bestConfidence) {
          bestConfidence = label.confidence;
        }
      }
    }

    final rawLabels = labels.map((l) => l.label).toList();
    final isBottle = matched.isNotEmpty;
    final confidence = isBottle ? bestConfidence.clamp(0.0, 1.0) : 0.0;

    return BottleRecognitionResult(
      isBottle: isBottle,
      confidence: confidence,
      matchedLabels: matched,
      rawLabels: rawLabels,
    );
  }

  BottleCondition _analyzeBottleConditionFromLabels(List<ImageLabel> labels) {
      debugPrint(
        '🔍 Bottle AI Labels: ${labels.map((l) => '${l.label} (${(l.confidence * 100).toStringAsFixed(1)}%)').join(', ')}',
      );

      // Extract damage and intact indicators from labels
      final damageIndicators = <String>[];
      final intactIndicators = <String>[];

      for (final label in labels) {
        final labelLower = label.label.toLowerCase();

        if (_damageKeywords.any(
          (kw) => labelLower.contains(kw),
        )) {
          damageIndicators.add(label.label);
        }

        if (_intactKeywords.any(
          (kw) => labelLower.contains(kw),
        )) {
          intactIndicators.add(label.label);
        }
      }

      final rawLabels = labels.map((l) => l.label).toList();

      // Determine status based on detected indicators
      String status;
      double confidence;

      if (damageIndicators.isNotEmpty && intactIndicators.isEmpty) {
        // Clear damage indicators, no intact indicators → dropped
        status = 'dropped';
        confidence = 0.85;
      } else if (intactIndicators.isNotEmpty && damageIndicators.isEmpty) {
        // Clear intact indicators, no damage indicators → non-dropped
        status = 'non-dropped';
        confidence = 0.85;
      } else if (damageIndicators.isNotEmpty && intactIndicators.isNotEmpty) {
        // Both damage and intact detected → likely dropped (damage takes priority)
        status = 'dropped';
        confidence = 0.70;
      } else if (intactIndicators.isNotEmpty) {
        // Only intact → non-dropped
        status = 'non-dropped';
        confidence = 0.75;
      } else {
        // No clear indicators → uncertain
        status = 'unknown';
        confidence = 0.5;
      }

      return BottleCondition(
        status: status,
        confidence: confidence,
        detectedDamageIndicators: damageIndicators,
        detectedIntactIndicators: intactIndicators,
        rawLabels: rawLabels,
      );
  }

  /// Check if bottle is likely dropped (damaged)
  bool isBottleDropped(BottleCondition condition) {
    return condition.status == 'dropped' && condition.confidence >= 0.6;
  }

  /// Check if bottle is likely non-dropped (intact)
  bool isBottleIntact(BottleCondition condition) {
    return condition.status == 'non-dropped' && condition.confidence >= 0.6;
  }

  void dispose() {
    try {
      _imageLabeler.close();
    } catch (_) {}
  }
}
