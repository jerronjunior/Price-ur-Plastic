import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/notification_provider.dart';
import 'app_header.dart';
import 'bottom_nav_bar.dart';
import 'notification_panel.dart';

/// Persistent chrome for the Home/Leaderboard/Rewards/Profile tabs.
/// The header and bottom nav bar live here exactly once — switching tabs
/// only swaps [navigationShell]'s body, never rebuilds this chrome.
class AppShell extends StatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _showNotificationPanel = false;

  static const _titles = ['HOME', 'LEADERBOARD', 'REWARDS', 'PROFILE'];

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    return Scaffold(
      bottomNavigationBar: AppBottomNavBar(
        currentIndex: index,
        onTabSelected: widget.navigationShell.goBranch,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              AppHeader(
                title: _titles[index],
                onProfileTap: index == 3
                    ? null
                    : () => widget.navigationShell.goBranch(3),
                onNotificationTap: () {
                  if (!_showNotificationPanel) {
                    context.read<NotificationProvider>().markAllAsRead();
                  }
                  setState(
                      () => _showNotificationPanel = !_showNotificationPanel);
                },
              ),
              Expanded(child: widget.navigationShell),
            ],
          ),
          if (_showNotificationPanel)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _showNotificationPanel = false),
                child: Container(
                  color: Colors.black38,
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      notifications: context
                          .watch<NotificationProvider>()
                          .notifications,
                      onClose: () =>
                          setState(() => _showNotificationPanel = false),
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
