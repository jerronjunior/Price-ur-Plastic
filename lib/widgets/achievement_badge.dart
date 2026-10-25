import 'package:flutter/material.dart';
import '../services/achievements/achievement_definitions.dart';

const kTierColors = <int, Color>{
  1: Color(0xFFBF8A5E),
  2: Color(0xFFB0BEC5),
  3: Color(0xFFFFA000),
};

class AchievementBadge extends StatelessWidget {
  const AchievementBadge({super.key, required this.achievement, required this.unlocked, this.size = 64});
  final AchievementDef achievement;
  final bool unlocked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ring = unlocked ? (kTierColors[achievement.tier] ?? kTierColors[1]!) : Colors.grey.shade300;
    final icon = Icon(achievement.icon, size: size * .42, color: unlocked ? const Color(0xFF2E7D32) : Colors.grey.shade500);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: ring, width: size * .07), boxShadow: unlocked ? [BoxShadow(color: ring.withValues(alpha: .35), blurRadius: 10, offset: const Offset(0, 3))] : null),
          child: icon,
        ),
        if (!unlocked)
          Positioned(right: -1, bottom: -1, child: Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: Colors.grey.shade600, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)), child: Icon(Icons.lock, size: size * .2, color: Colors.white))),
      ]),
    );
  }
}
