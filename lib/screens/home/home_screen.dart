import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../services/firestore_service.dart';
import '../../models/bin_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';

/// Home: points, bottles count, XP progress, and stat boxes.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _showWelcome = false;
  bool _showNotificationPanel = false;

  @override
  void initState() {
    super.initState();
    // Check if user just logged in
    final authProvider = context.read<AuthProvider>();
    if (authProvider.justLoggedIn) {
      _showWelcome = true;
      // Hide welcome message after 2 seconds
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _showWelcome = false;
          });
          // Reset the flag so it doesn't show again
          authProvider.resetWelcomeMessage();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/'),
      body: Stack(
        children: [
          // Main Content
          StreamBuilder(
            stream: context.read<AuthProvider>().userStream,
            builder: (context, snapshot) {
              final user = snapshot.data ?? context.read<AuthProvider>().user;
              final name = user?.name ?? 'User';
              final points = user?.totalPoints ?? 0;
              final bottles = user?.totalBottles ?? 0;
              final profileImageUrl = user?.profileImageUrl;

              ImageProvider? profileImageProvider;
              if (profileImageUrl != null && profileImageUrl.isNotEmpty) {
                if (profileImageUrl.startsWith('http://') ||
                    profileImageUrl.startsWith('https://')) {
                  profileImageProvider = NetworkImage(profileImageUrl);
                } else {
                  final filePath = profileImageUrl.startsWith('file://')
                      ? Uri.parse(profileImageUrl).toFilePath()
                      : profileImageUrl;
                  final localFile = File(filePath);
                  if (localFile.existsSync()) {
                    profileImageProvider = FileImage(localFile);
                  }
                }
              }

              return SingleChildScrollView(
                child: Column(
                  children: [
                    // Blue Header with HOME title
                    Container(
                      width: double.infinity,
                      color: AppTheme.primaryBlue,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.person, color: Colors.white),
                            onPressed: () => context.push('/profile'),
                          ),
                          const Text(
                            'HOME',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.notifications,
                                    color: Colors.white),
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
                            onPressed: () {
                              if (!_showNotificationPanel) {
                                context
                                    .read<NotificationProvider>()
                                    .markAllAsRead();
                              }
                              setState(() {
                                _showNotificationPanel =
                                    !_showNotificationPanel;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    // Welcome Section - Green rounded box with animation
                    AnimatedOpacity(
                      opacity: _showWelcome ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        height: _showWelcome ? null : 0,
                        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D32),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Text(
                          'Welcome back, $name!',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // Greeting Section - Blue rounded box
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryBlue,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Hello ${name.split(' ').first}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  "Let's recycle today! ♻️",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Avatar circle
                          CircleAvatar(
                            radius: 32,
                            backgroundColor: Colors.white.withOpacity(0.3),
                            backgroundImage: profileImageProvider,
                            child: profileImageProvider == null
                                ? Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // 4-box Grid: Points, Data Image, Bottle Count, Location Explored
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _StatBox(
                                  icon: '⭐',
                                  value: '$points',
                                  label: 'POINTS',
                                ),
                              ),
                              const SizedBox(width: 16),
                              const Expanded(
                                child: _StatBox(
                                  icon: '📊',
                                  value: '0',
                                  label: 'DATA IMAGE',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: _StatBox(
                                  imagePath: 'assets/images/logo.jpeg',
                                  value: '$bottles',
                                  label: 'BOTTLE COUNT',
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: GestureDetector(
                                  onTap: () => context.push('/map'),
                                  child: StreamBuilder<List<BinModel>>(
                                    stream: FirestoreService().getAllBinsStream(),
                                    builder: (context, snap) {
                                      final count = snap.data?.length ?? 0;
                                      return _StatBox(
                                        icon: '📍',
                                        value: '$count',
                                        label: 'LOCATION EXPLORED',
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // XP Progress bar section - inside container
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'XP Progress',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '$points XP',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: (points % 100) / 100,
                                minHeight: 12,
                                backgroundColor: Colors.grey.shade300,
                                valueColor: const AlwaysStoppedAnimation(
                                  AppTheme.primaryBlue,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Help section with press me button - inside container
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            Text(
                              'Scan bin QR and drop bottles to earn points',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () => context.push('/scan'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey.shade400,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 40,
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: const Text(
                                'press me',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
          // Notification Panel Overlay
          if (_showNotificationPanel)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () {
                  // Close panel when tapping outside
                  setState(() {
                    _showNotificationPanel = false;
                  });
                },
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      notifications:
                          context.watch<NotificationProvider>().notifications,
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

class _StatBox extends StatelessWidget {
  const _StatBox({
    this.icon,
    this.imagePath,
    required this.value,
    required this.label,
  });

  final String? icon;
  final String? imagePath;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (imagePath != null)
            Image.asset(
              imagePath!,
              width: 36,
              height: 36,
              fit: BoxFit.contain,
            )
          else
            Text(
              icon ?? '',
              style: const TextStyle(fontSize: 32),
            ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.primaryBlue,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

