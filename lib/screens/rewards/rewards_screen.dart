import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';

/// Static reward tiers: Bronze 50, Silver 200, Gold 500.
class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final points = user?.totalPoints ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewards'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: AppTheme.primaryLight.withValues(alpha: 0.2),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      'Your points',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: AppTheme.primaryDark,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$points',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryGreen,
                          ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
            _TierCard(
              title: 'Bronze',
              pointsRequired: AppConstants.bronzePoints,
              currentPoints: points,
              color: const Color(0xFFCD7F32),
              icon: Icons.workspace_premium,
            ),
            const SizedBox(height: 16),
            _TierCard(
              title: 'Silver',
              pointsRequired: AppConstants.silverPoints,
              currentPoints: points,
              color: const Color(0xFFC0C0C0),
              icon: Icons.workspace_premium,
            ),
            const SizedBox(height: 16),
            _TierCard(
              title: 'Gold',
              pointsRequired: AppConstants.goldPoints,
              currentPoints: points,
              color: const Color(0xFFFFD700),
              icon: Icons.workspace_premium,
            ),
            const SizedBox(height: 24),
            Text(
              'More rewards coming in future updates!',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.title,
    required this.pointsRequired,
    required this.currentPoints,
    required this.color,
    required this.icon,
  });

  final String title;
  final int pointsRequired;
  final int currentPoints;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final unlocked = currentPoints >= pointsRequired;
    final progress = (currentPoints / pointsRequired).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.3),
              radius: 32,
              child: Icon(icon, color: color, size: 36),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    unlocked
                        ? 'Unlocked!'
                        : '$currentPoints / $pointsRequired points',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (unlocked)
              const Icon(Icons.check_circle, color: AppTheme.primaryGreen),
          ],
        ),
      ),
    );
  }
}
