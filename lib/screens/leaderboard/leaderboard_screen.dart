import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../../services/firestore_service.dart';

/// Top 10 users by total points, real-time Firestore stream.
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final firestore = context.read<FirestoreService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaderboard'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: StreamBuilder<List<UserModel>>(
        stream: firestore.leaderboardStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }
          final list = snapshot.data ?? [];
          if (list.isEmpty) {
            return const Center(child: Text('No scores yet. Be the first!'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, index) {
              final user = list[index];
              final rank = index + 1;
              return _LeaderboardTile(
                rank: rank,
                name: user.name,
                points: user.totalPoints,
                bottles: user.totalBottles,
              );
            },
          );
        },
      ),
    );
  }
}

class _LeaderboardTile extends StatelessWidget {
  const _LeaderboardTile({
    required this.rank,
    required this.name,
    required this.points,
    required this.bottles,
  });

  final int rank;
  final String name;
  final int points;
  final int bottles;

  @override
  Widget build(BuildContext context) {
    IconData? medal;
    Color? medalColor;
    if (rank == 1) {
      medal = Icons.emoji_events;
      medalColor = const Color(0xFFFFD700);
    } else if (rank == 2) {
      medal = Icons.emoji_events;
      medalColor = const Color(0xFFC0C0C0);
    } else if (rank == 3) {
      medal = Icons.emoji_events;
      medalColor = const Color(0xFFCD7F32);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primaryLight.withValues(alpha: 0.3),
          child: medal != null
              ? Icon(medal, color: medalColor, size: 28)
              : Text(
                  '$rank',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryDark,
                  ),
                ),
        ),
        title: Text(
          name.isEmpty ? 'Anonymous' : name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('$bottles bottles recycled'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '$points',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppTheme.primaryGreen,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              'points',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
