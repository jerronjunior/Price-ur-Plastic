import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/theme.dart';

/// Shared bottom navigation bar widget
class AppBottomNavBar extends StatelessWidget {
  final String currentRoute;

  const AppBottomNavBar({
    required this.currentRoute,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Colors.grey.shade200, width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BottomNavItem(
            icon: Icons.home,
            label: 'Home',
            isActive: currentRoute == '/' || currentRoute == '/home',
            onTap: () => context.go('/'),
          ),
          _BottomNavItem(
            icon: Icons.qr_code_2,
            label: 'Scan',
            isActive: currentRoute == '/scan' || currentRoute == '/scan-flow',
            onTap: () => context.go('/scan'),
          ),
          _BottomNavItem(
            icon: Icons.leaderboard,
            label: 'Leaderboard',
            isActive: currentRoute == '/leaderboard',
            onTap: () => context.go('/leaderboard'),
          ),
          _BottomNavItem(
            icon: Icons.card_giftcard,
            label: 'Rewards',
            isActive: currentRoute == '/rewards',
            onTap: () => context.go('/rewards'),
          ),
          _BottomNavItem(
            icon: Icons.person,
            label: 'Profile',
            isActive: currentRoute == '/profile',
            onTap: () => context.go('/profile'),
          ),
        ],
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isActive ? AppTheme.primaryBlue : Colors.grey.shade700,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: isActive ? AppTheme.primaryBlue : Colors.grey.shade700,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
