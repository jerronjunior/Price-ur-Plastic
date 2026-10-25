import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'achievement_definitions.dart';

class AchievementProgress {
  const AchievementProgress({required this.stats, required this.unlocked});
  final Map<String, int> stats;
  final Set<String> unlocked;
}

class AchievementService {
  AchievementService({FirebaseFirestore? firestore, FirebaseAuth? auth}) : _db = firestore ?? FirebaseFirestore.instance, _auth = auth ?? FirebaseAuth.instance;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  Future<AchievementProgress?> loadProgress() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return const AchievementProgress(stats: {}, unlocked: {});
    try {
      final user = await _db.collection('users').doc(uid).get();
      final data = user.data() ?? const <String, dynamic>{};
      final rawStats = data['achievementStats'];
      final stats = <String, int>{};
      if (rawStats is Map) {
        for (final entry in rawStats.entries) {
          if (entry.value is num) stats[entry.key.toString()] = (entry.value as num).toInt();
        }
      }
      stats['bottlesInserted'] ??= _intValue(data['totalBottles']);
      final rawUnlocked = data['unlockedAchievements'];
      final unlocked = rawUnlocked is Iterable ? rawUnlocked.map((value) => value.toString()).toSet() : <String>{};
      for (final achievement in kAchievements) {
        if ((stats[achievement.category.statField] ?? 0) >= achievement.threshold) unlocked.add(achievement.id);
      }
      return AchievementProgress(stats: stats, unlocked: unlocked);
    } catch (_) {
      return const AchievementProgress(stats: {}, unlocked: {});
    }
  }

  Future<void> incrementStat(String field, {int amount = 1}) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    await _db.collection('users').doc(uid).set({'achievementStats.$field': FieldValue.increment(amount)}, SetOptions(merge: true));
  }

  static int _intValue(dynamic value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}
