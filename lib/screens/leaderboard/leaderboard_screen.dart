import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';

/// Leaderboard screen showing global rankings, friends, and achievements
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  String _activeTab = 'Global'; // Global, Friends, Achievements
  bool _showNotificationPanel = false;

  // Color scheme for top 3 rankings
  final Map<int, Color> topColors = {
    1: const Color(0xFFFFA500), // Orange
    2: const Color(0xFF4A7C7E), // Teal
    3: const Color(0xFF6B5B4C), // Brown
  };

  final Map<int, String> medalEmojis = {
    1: '🏆',
    2: '🥈',
    3: '🥉',
  };

  @override
  Widget build(BuildContext context) {
    final firestore = context.read<FirestoreService>();
    final authProvider = context.read<AuthProvider>();
    final currentUser = authProvider.user;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/leaderboard'),
      body: Stack(
        children: [
          SingleChildScrollView(
            child: Column(
          children: [
            // Blue Header
            Container(
              width: double.infinity,
              color: AppTheme.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.person, color: Colors.white),
                    onPressed: () => context.push('/profile'),
                  ),
                  const Text(
                    'LEADERBOARD',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.notifications, color: Colors.white),
                    onPressed: () {
                      setState(() {
                        _showNotificationPanel = !_showNotificationPanel;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Tabs: Global, Friends, Achievements
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _TabButton(
                    icon: '🌍',
                    label: 'Global',
                    isActive: _activeTab == 'Global',
                    onTap: () {
                      setState(() => _activeTab = 'Global');
                    },
                  ),
                  const SizedBox(width: 12),
                  _TabButton(
                    icon: '👥',
                    label: 'Friends',
                    isActive: _activeTab == 'Friends',
                    onTap: () {
                      setState(() => _activeTab = 'Friends');
                    },
                  ),
                  const SizedBox(width: 12),
                  _TabButton(
                    icon: '🏅',
                    label: 'Achievements',
                    isActive: _activeTab == 'Achievements',
                    onTap: () {
                      setState(() => _activeTab = 'Achievements');
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Leaderboard Section Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    '🏆 ',
                    style: TextStyle(fontSize: 28),
                  ),
                  Text(
                    'Leaderboard',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Content based on active tab
            if (_activeTab == 'Global') ...[
              // Leaderboard List from Firestore - Top 10 users
              StreamBuilder<List<UserModel>>(
                stream: firestore.leaderboardStream(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: SizedBox(
                        height: 300,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                      ),
                    );
                  }

                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text('Error: ${snapshot.error}'),
                    );
                  }

                  final leaderboardUsers = snapshot.data ?? [];

                  if (leaderboardUsers.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 60),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.leaderboard,
                              size: 64,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No rankings yet',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        // Top 10 users
                        ...leaderboardUsers.asMap().entries.map((entry) {
                          final index = entry.key;
                          final rank = index + 1;
                          final user = entry.value;

                          final backgroundColor = topColors[rank] ?? Colors.white;
                          final medal = medalEmojis[rank] ?? '$rank';

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _RankingCard(
                              rank: rank,
                              username: user.name,
                              bottles: user.totalBottles,
                              points: user.totalPoints,
                              backgroundColor: backgroundColor,
                              medal: medal,
                            ),
                          );
                        }),
                        // Show current user if not in top 10
                        if (currentUser != null &&
                            !leaderboardUsers.any(
                              (u) => u.userId == currentUser.userId,
                            ))
                          Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: AppTheme.primaryBlue,
                                width: 2,
                                strokeAlign: BorderSide.strokeAlignOutside,
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: _RankingCard(
                              rank: 11,
                              username: currentUser.name,
                              bottles: currentUser.totalBottles,
                              points: currentUser.totalPoints,
                              backgroundColor: const Color(0xFFE3F2FD),
                              medal: '👤',
                              isCurrentUser: true,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ] else if (_activeTab == 'Friends') ...[
              // Friends tab - Coming Soon
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.people_outline,
                        size: 80,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Coming Soon!',
                        style: TextStyle(
                          fontSize: 24,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Friends leaderboard feature\nis under development',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppTheme.primaryBlue.withOpacity(0.3),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: AppTheme.primaryBlue,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Compete with your friends soon!',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (_activeTab == 'Achievements') ...[
              // Achievements tab - Show users with achievements or empty state
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.emoji_events_outlined,
                        size: 80,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'No Achievements Yet',
                        style: TextStyle(
                          fontSize: 20,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Achievement system coming soon!\nStart recycling to earn achievements',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
          // Notification Panel Overlay
          if (_showNotificationPanel)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showNotificationPanel = false;
                  });
                },
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      onClose: () {
                        setState(() {
                          _showNotificationPanel = false;
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? AppTheme.primaryBlue : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: !isActive
              ? Border.all(color: Colors.grey.shade300, width: 1.5)
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.grey.shade700,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({
    required this.rank,
    required this.username,
    required this.bottles,
    required this.points,
    required this.backgroundColor,
    required this.medal,
    this.isCurrentUser = false,
  });

  final int rank;
  final String username;
  final int bottles;
  final int points;
  final Color backgroundColor;
  final String medal;
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context) {
    final textColor = backgroundColor == Colors.white
        ? Colors.black
        : backgroundColor == const Color(0xFFE3F2FD)
            ? Colors.black
            : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Rank/Medal
          SizedBox(
            width: 40,
            child: Center(
              child: Text(
                rank <= 3 ? medal : '$rank',
                style: TextStyle(
                  fontSize: rank <= 3 ? 20 : 16,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Username and Bottles
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  username,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                Text(
                  '$bottles bottles',
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
          // Points
          Text(
            '$points pts',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
