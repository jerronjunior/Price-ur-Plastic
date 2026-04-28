import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../screens/auth/auth_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/leaderboard/leaderboard_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/rewards/rewards_screen.dart';
import '../screens/scan/scan_bin_flow_screen.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../screens/admin/manage_bins_screen.dart';
import '../screens/admin/manage_rewards_screen.dart';
import '../screens/startup/splash_screen.dart';
import '../screens/startup/welcome_screen.dart';
import '../screens/map/map_screen.dart';

/// App routing with auth redirect.
GoRouter createAppRouter(AuthProvider authProvider) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: GoRouterRefreshStream(authProvider.authStateChanges),
    redirect: (context, state) {
      final loggedIn = authProvider.isLoggedIn;
      final location = state.matchedLocation;
      final onAuth = location == '/login' || location == '/register';
      final onStartup = location == '/splash' || location == '/welcome';
      if (onStartup) return null;
      if (!loggedIn && !onAuth) return '/login';
      if (loggedIn && onAuth) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, __) => const SplashScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (_, __) => const WelcomeScreen(),
      ),
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
        builder: (_, __) => const ScanBinFlowScreen(),
      ),
      GoRoute(
        path: '/scan-flow',
        builder: (_, __) => const ScanBinFlowScreen(),
      ),
      GoRoute(
        path: '/scan-bin',
        builder: (_, __) => const ScanBinFlowScreen(),
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
      GoRoute(
        path: '/map',
        builder: (_, __) => const MapScreen(),
      ),
      GoRoute(
        path: '/admin',
        builder: (_, __) => const AdminDashboardScreen(),
      ),
      GoRoute(
        path: '/admin/bins',
        builder: (_, __) => const ManageBinsScreen(),
      ),
      GoRoute(
        path: '/admin/rewards',
        builder: (_, __) => const ManageRewardsScreen(),
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
