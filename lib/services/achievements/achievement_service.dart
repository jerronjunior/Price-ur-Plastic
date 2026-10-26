import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
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

  /// Records a qualifying action and awards achievements crossed by the new
  /// counter value. Achievement data stays in the existing
  /// `achievementStats` shape used by the app.
  Future<List<AchievementDef>> recordProgress({
    required AchievementCategory category,
    int incrementBy = 1,
    int? setValueDirectly,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return [];
    final userRef = _db.collection('users').doc(uid);

    try {
      return await _db.runTransaction((tx) async {
        final snapshot = await tx.get(userRef);
        final data = snapshot.data() ?? <String, dynamic>{};
        final rawStats = data['achievementStats'];
        final stats = <String, dynamic>{};
        if (rawStats is Map) {
          stats.addAll(Map<String, dynamic>.from(rawStats));
        }

        final field = category.statField;
        final current = _intValue(stats[field]);
        final next = setValueDirectly ?? (current + incrementBy);
        stats[field] = next;

        final rawUnlocked = data['unlockedAchievements'];
        final unlocked = rawUnlocked is Iterable
            ? rawUnlocked.map((value) => value.toString()).toSet()
            : <String>{};
        final newlyUnlocked = <AchievementDef>[];
        var pointsToAdd = 0;

        for (final achievement in kAchievementsByCategory[category] ?? const []) {
          if (!unlocked.contains(achievement.id) &&
              next >= achievement.threshold) {
            unlocked.add(achievement.id);
            newlyUnlocked.add(achievement);
            pointsToAdd = (pointsToAdd + achievement.points).toInt();
          }
        }

        tx.set(
          userRef,
          {
            'achievementStats': stats,
            'unlockedAchievements': unlocked.toList(),
            if (pointsToAdd > 0)
              'totalPoints': FieldValue.increment(pointsToAdd),
          },
          SetOptions(merge: true),
        );

        for (final achievement in newlyUnlocked) {
          final logRef = _db.collection('achievement_unlocks').doc();
          tx.set(logRef, {
            'userId': uid,
            'achievementId': achievement.id,
            'points': achievement.points,
            'unlockedAt': FieldValue.serverTimestamp(),
          });
        }
        return newlyUnlocked;
      });
    } catch (error) {
      debugPrint('[Achievements] recordProgress failed: $error');
      return [];
    }
  }

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
