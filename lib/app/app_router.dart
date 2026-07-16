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
import '../widgets/app_shell.dart';

/// App routing with auth redirect.
GoRouter createAppRouter(AuthProvider authProvider) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: GoRouterRefreshStream(authProvider.authStateChanges),
    redirect: (context, state) {
      final loggedIn = authProvider.isLoggedIn;
      final isAdmin = authProvider.isAdmin;
      final location = state.matchedLocation;
      final onAuth = location == '/login' || location == '/register';
      final onStartup = location == '/splash' || location == '/welcome';
        final onAdminRoute = location == '/admin' ||
          location.startsWith('/admin/');
      final onUserRoute = location == '/' ||
          location == '/home' ||
          location == '/scan' ||
          location == '/scan-flow' ||
          location == '/scan-bin' ||
          location == '/leaderboard' ||
          location == '/profile' ||
          location == '/rewards' ||
          location == '/map';
      if (onStartup) return null;
      if (!loggedIn && !onAuth) return '/login';
      if (!loggedIn) return null;
      if (isAdmin) {
        if (onAuth || onUserRoute) return '/admin';
        return null;
      }
      if (onAuth || onAdminRoute) return '/';
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
        path: '/login',
        builder: (_, __) => const AuthScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (_, __) => const AuthScreen(),
      ),
      // Home/Leaderboard/Rewards/Profile share one persistent header +
      // bottom nav bar (AppShell) — switching tabs only swaps the content.
      StatefulShellRoute.indexedStack(
        builder: (_, __, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
            GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/leaderboard',
              builder: (_, __) => const LeaderboardScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/rewards',
              builder: (_, __) => const RewardsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/profile',
              builder: (_, __) => const ProfileScreen(),
            ),
          ]),
        ],
      ),
      // Scan is an immersive full-screen camera flow, pushed on top of the
      // shell (no shared header/nav bar) — matches its existing UX.
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
