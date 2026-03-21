import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/bottle_ai_service.dart';

/// Provides a singleton BottleAIService instance
final bottleAIServiceProvider = Provider<BottleAIService>((ref) {
  return BottleAIService();
});

/// Holds the current bottle condition state
/// Can be watched to update UI when condition changes
final bottleConditionProvider = StateProvider<BottleCondition?>((ref) {
  return null;
});
