import 'package:flutter/material.dart' show IconData, Icons;

enum AchievementCategory { insertion, binDiscovery, streak, update, share, friends }

extension AchievementCategoryX on AchievementCategory {
  String get label => switch (this) {
        AchievementCategory.insertion => 'Insertion',
        AchievementCategory.binDiscovery => 'Bin Discovery',
        AchievementCategory.streak => 'Consistency',
        AchievementCategory.update => 'Bottle Updates',
        AchievementCategory.share => 'Social Sharing',
        AchievementCategory.friends => 'Social / Referral',
      };

  String get emoji => switch (this) {
        AchievementCategory.insertion => '🍾',
        AchievementCategory.binDiscovery => '📍',
        AchievementCategory.streak => '🔥',
        AchievementCategory.update => '✏️',
        AchievementCategory.share => '📢',
        AchievementCategory.friends => '👥',
      };

  String get statField => switch (this) {
        AchievementCategory.insertion => 'bottlesInserted',
        AchievementCategory.binDiscovery => 'binsLocated',
        AchievementCategory.streak => 'longestStreak',
        AchievementCategory.update => 'bottlesUpdated',
        AchievementCategory.share => 'sharesCount',
        AchievementCategory.friends => 'friendsCount',
      };
}

class AchievementDef {
  const AchievementDef({
    required this.id,
    required this.category,
    required this.title,
    required this.description,
    required this.tier,
    required this.threshold,
    required this.points,
    required this.icon,
    this.badgeAsset,
  });

  final String id;
  final AchievementCategory category;
  final String title;
  final String description;
  final int tier;
  final int threshold;
  final int points;
  final IconData icon;
  final String? badgeAsset;
}

const kAchievements = <AchievementDef>[
  AchievementDef(id: 'insert_1', category: AchievementCategory.insertion, title: 'Baby Step', description: 'Insert 1 bottle', tier: 1, threshold: 1, points: 10, icon: Icons.local_drink),
  AchievementDef(id: 'insert_10', category: AchievementCategory.insertion, title: 'Getting Started', description: 'Insert 10 bottles', tier: 2, threshold: 10, points: 20, icon: Icons.local_drink),
  AchievementDef(id: 'insert_100', category: AchievementCategory.insertion, title: 'Eco-Warrior', description: 'Insert 100 bottles', tier: 3, threshold: 100, points: 50, icon: Icons.local_drink),
  AchievementDef(id: 'bin_1', category: AchievementCategory.binDiscovery, title: 'Curious', description: 'Locate 1 bin', tier: 1, threshold: 1, points: 10, icon: Icons.location_on),
  AchievementDef(id: 'bin_10', category: AchievementCategory.binDiscovery, title: 'Lucky', description: 'Locate 10 bins', tier: 2, threshold: 10, points: 20, icon: Icons.location_on),
  AchievementDef(id: 'bin_100', category: AchievementCategory.binDiscovery, title: 'Explorer', description: 'Locate 100 bins', tier: 3, threshold: 100, points: 50, icon: Icons.location_on),
  AchievementDef(id: 'streak_1', category: AchievementCategory.streak, title: 'Day 1', description: 'Reach a 1 day streak', tier: 1, threshold: 1, points: 10, icon: Icons.local_fire_department),
  AchievementDef(id: 'streak_7', category: AchievementCategory.streak, title: 'Behaviour', description: 'Reach a 1 week streak', tier: 2, threshold: 7, points: 20, icon: Icons.date_range),
  AchievementDef(id: 'streak_30', category: AchievementCategory.streak, title: 'Habit', description: 'Reach a 1 month streak', tier: 3, threshold: 30, points: 50, icon: Icons.local_fire_department),
  AchievementDef(id: 'update_1', category: AchievementCategory.update, title: 'Helper', description: 'Update 1 bottle', tier: 1, threshold: 1, points: 10, icon: Icons.edit),
  AchievementDef(id: 'update_10', category: AchievementCategory.update, title: 'Contributor', description: 'Update 10 bottles', tier: 2, threshold: 10, points: 20, icon: Icons.edit),
  AchievementDef(id: 'update_100', category: AchievementCategory.update, title: 'Data Champion', description: 'Update 100 bottles', tier: 3, threshold: 100, points: 50, icon: Icons.edit),
  AchievementDef(id: 'share_1', category: AchievementCategory.share, title: 'Do You Know', description: 'Share 1 time', tier: 1, threshold: 1, points: 10, icon: Icons.share),
  AchievementDef(id: 'share_10', category: AchievementCategory.share, title: 'Influencer', description: 'Share 10 times', tier: 2, threshold: 10, points: 20, icon: Icons.campaign),
  AchievementDef(id: 'share_100', category: AchievementCategory.share, title: 'Social Media Star', description: 'Share 100 times', tier: 3, threshold: 100, points: 50, icon: Icons.stars),
  AchievementDef(id: 'friend_1', category: AchievementCategory.friends, title: 'Friend', description: 'Add 1 friend', tier: 1, threshold: 1, points: 10, icon: Icons.person_add),
  AchievementDef(id: 'friend_100', category: AchievementCategory.friends, title: 'Best Friend', description: 'Add 100 friends', tier: 2, threshold: 100, points: 20, icon: Icons.group),
  AchievementDef(id: 'friend_1000', category: AchievementCategory.friends, title: 'Friend in Need', description: 'Add 1000 friends', tier: 3, threshold: 1000, points: 50, icon: Icons.group),
];

Map<AchievementCategory, List<AchievementDef>> get kAchievementsByCategory {
  final result = <AchievementCategory, List<AchievementDef>>{};
  for (final achievement in kAchievements) {
    result.putIfAbsent(achievement.category, () => <AchievementDef>[]).add(achievement);
  }
  return result;
}

AchievementDef? achievementById(String id) => kAchievements.cast<AchievementDef?>().firstWhere((a) => a?.id == id, orElse: () => null);
