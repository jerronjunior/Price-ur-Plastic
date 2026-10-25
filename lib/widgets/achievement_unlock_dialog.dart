import 'package:flutter/material.dart';
import '../services/achievements/achievement_definitions.dart';
import 'achievement_badge.dart';

Future<void> showAchievementUnlocks(BuildContext context, List<AchievementDef> achievements) async {
  for (final achievement in achievements) {
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (_) => _UnlockDialog(achievement: achievement));
  }
}

class _UnlockDialog extends StatelessWidget {
  const _UnlockDialog({required this.achievement});
  final AchievementDef achievement;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Achievement Unlocked!'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          AchievementBadge(achievement: achievement, unlocked: true, size: 88),
          const SizedBox(height: 12),
          Text(achievement.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1B5E20))),
          const SizedBox(height: 4),
          Text(achievement.description, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text('+${achievement.points} points', style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.bold)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Awesome!'))],
      );
}
