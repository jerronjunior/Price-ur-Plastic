import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/rewards/rewards_screen.dart';
import '../screens/scan/scan_flow_screen.dart';

/// App routing with auth redirect.
GoRouter createAppRouter(AuthProvider authProvider) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream(authProvider.authStateChanges),
    redirect: (context, state) {
      final loggedIn = authProvider.isLoggedIn;
      final onAuth = state.matchedLocation == '/login' || state.matchedLocation == '/register';
      if (!loggedIn && !onAuth) return '/login';
      if (loggedIn && onAuth) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const HomeScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (_, __) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/scan',
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

/// Notifies router when auth state changes (for redirect).
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }
  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
