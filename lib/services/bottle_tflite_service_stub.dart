import 'package:flutter/foundation.dart';

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
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> init() async {
    _ready = false;
    debugPrint('TFLite is not available on web.');
  }

  Future<TfliteBottleResult> detectFromFilePath(String path) async {
    return const TfliteBottleResult(
      isBottle: false,
      confidence: 0,
      label: 'TFLite unavailable on web',
    );
  }

  void dispose() {}
}
