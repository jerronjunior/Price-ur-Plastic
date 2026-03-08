import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../screens/auth/auth_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/rewards/rewards_screen.dart';
import '../screens/scan/scan_landing_screen.dart';
import '../screens/scan/scan_flow_screen.dart';

/// App routing with auth redirect.
GoRouter createAppRouter(AuthProvider authProvider) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: authProvider,
    redirect: (context, state) {
      final loggedIn = authProvider.isLoggedIn;
      final onAuth = state.matchedLocation == '/login' || state.matchedLocation == '/register';

      // Always allow root/home so the app never opens to a blank/blocked page.
      if (!loggedIn && (state.matchedLocation == '/' || state.matchedLocation == '/home')) {
        return null;
      }

      if (!loggedIn && !onAuth) return '/';
      if (loggedIn && onAuth) return '/';
      return null;
    },
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Page Error')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            state.error?.toString() ?? 'Unknown routing error.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const HomeScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (_, __) => const HomeScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, __) => const AuthScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (_, __) => const AuthScreen(),
      ),
      GoRoute(
        path: '/scan',
        builder: (_, __) => const ScanLandingScreen(),
      ),
      GoRoute(
        path: '/scan-flow',
        builder: (_, __) => const ScanFlowScreen(),
      ),
      GoRoute(
        path: '/leaderboard',
        builder: (_, __) => const LeaderboardScreen(),
      ),
      GoRoute(
        path: '/profile',
        builder: (_, __) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/rewards',
        builder: (_, __) => const RewardsScreen(),
      ),
    ],
  );
}
