import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme.dart';
import '../providers/notification_provider.dart';

/// Shared page header — identical on every tab, only [title] changes.
class AppHeader extends StatelessWidget {
  const AppHeader({
    required this.title,
    required this.onNotificationTap,
    this.onProfileTap,
    super.key,
  });

  final String title;
  final VoidCallback onNotificationTap;
  final VoidCallback? onProfileTap;

  @override
  Widget build(BuildContext context) {
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    return Container(
      width: double.infinity,
      color: AppTheme.primaryBlue,
      padding: EdgeInsets.fromLTRB(
        8,
        8 + MediaQuery.paddingOf(context).top,
        8,
        20,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white),
            onPressed: onProfileTap,
          ),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications, color: Colors.white),
                if (hasUnread)
                  const Positioned(
                    right: -1,
                    top: -1,
                    child: SizedBox(
                      width: 10,
                      height: 10,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: onNotificationTap,
          ),
        ],
      ),
    );
  }
}
