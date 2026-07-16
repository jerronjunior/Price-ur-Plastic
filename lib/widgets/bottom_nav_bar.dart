import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/theme.dart';
import '../providers/auth_provider.dart';

/// Shared bottom navigation bar — persists across tabs; only [currentIndex]
/// changes which item is highlighted. Branch order: 0=Home, 1=Leaderboard,
/// 2=Rewards, 3=Profile. Scan is not a shell branch (it's an immersive
/// full-screen camera flow pushed on top), so it's never "active" here.
class AppBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  const AppBottomNavBar({
    required this.currentIndex,
    required this.onTabSelected,
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
            isActive: currentIndex == 0,
            onTap: () => onTabSelected(0),
          ),
          // Hide leaderboard for admin users
          if (!(context.watch<AuthProvider>().isAdmin))
            _BottomNavItem(
              icon: Icons.leaderboard,
              label: 'Leaderboard',
              isActive: currentIndex == 1,
              onTap: () => onTabSelected(1),
            ),
          _BottomNavItem(
            icon: Icons.qr_code_2,
            label: 'Scan',
            isActive: false,
            onTap: () => context.push('/scan'),
          ),
          _BottomNavItem(
            icon: Icons.card_giftcard,
            label: 'Rewards',
            isActive: currentIndex == 2,
            onTap: () => onTabSelected(2),
          ),
          _BottomNavItem(
            icon: Icons.person,
            label: 'Profile',
            isActive: currentIndex == 3,
            onTap: () => onTabSelected(3),
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
