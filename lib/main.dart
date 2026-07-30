import 'dart:async' show unawaited, runZonedGuarded;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'core/theme.dart';
import 'app/app_router.dart';
import 'providers/auth_provider.dart';
import 'providers/notification_provider.dart';
import 'services/auth_service.dart';
import 'services/camera_service.dart';
import 'services/firestore_service.dart';
import 'firebase_options.dart';

void main() {
  // Any widget that throws mid-build (including Flutter framework
  // assertions like element-tree "is not our descendant" races) would
  // otherwise fall through to Flutter's default ErrorWidget, which dumps
  // the raw exception + stack trace onto the screen. Users should never
  // see that — log it for us instead and show a friendly fallback.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    debugPrint('[UI error] ${details.exception}\n${details.stack}');
    return const _FriendlyErrorFallback();
  };

  // Catches anything that still escapes the widget tree (e.g. errors
  // thrown from a callback outside the build phase) so it's logged
  // instead of silently crashing the isolate or surfacing to the user.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    String? startupError;

    // Warm the camera-list cache in the background so the first tap on Scan
    // doesn't pay for the availableCameras() platform-channel round trip on
    // top of the actual camera hardware open — shortens the black loading
    // screen users see the first time they open Scan each session.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(CameraService.getCameras());
    }

    try {
      final isSupportedFirebasePlatform = kIsWeb ||
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS;

      if (!isSupportedFirebasePlatform) {
        startupError =
            'This build is running on ${Platform.operatingSystem}.\n\n'
            'Firebase is configured for Android in this project.\n'
            'Run the app on an Android device/emulator using "flutter run -d android".';
      } else {
        // Check if Firebase is already initialized by native side to prevent duplicate-app errors
        try {
          // Wait a moment for native initialization to complete if it's happening
          await Future.delayed(const Duration(milliseconds: 500));

          if (Firebase.apps.isEmpty) {
            await Firebase.initializeApp(
              options: DefaultFirebaseOptions.currentPlatform,
            );
          }
        } on FirebaseException catch (e) {
          // If Firebase is already initialized by native side, that's OK - use the existing instance
          if (e.code == 'duplicate-app') {
            // This is expected - native Android initializes Firebase automatically
            // The app is already ready to use
          } else {
            rethrow;
          }
        }
      }
    } catch (e) {
      startupError =
          'Firebase initialization failed.\n\n$e\n\n'
          'Please verify Firebase setup and try running on Android.';
    }

    runApp(EcoRecycleApp(startupError: startupError));
  }, (error, stack) {
    debugPrint('[Uncaught error] $error\n$stack');
  });
}

/// Shown instead of Flutter's raw red/grey error screen whenever a widget
/// throws mid-build. Deliberately generic — the real exception only ever
/// goes to the console via ErrorWidget.builder above, never to the user.
class _FriendlyErrorFallback extends StatelessWidget {
  const _FriendlyErrorFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, color: Color(0xFFEF5350), size: 36),
          SizedBox(height: 12),
          Text(
            'Something went wrong loading this screen.\nPlease go back and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class EcoRecycleApp extends StatefulWidget {
  const EcoRecycleApp({super.key, this.startupError});

  final String? startupError;

  @override
  State<EcoRecycleApp> createState() => _EcoRecycleAppState();
}

class _EcoRecycleAppState extends State<EcoRecycleApp> {
  late final AuthService _authService;
  late final FirestoreService _firestoreService;
  late final AuthProvider _authProvider;
  late final GoRouter _router;
  bool _servicesReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.startupError != null) {
      return;
    }
    _authService = AuthService();
    _firestoreService = FirestoreService();
    _authProvider = AuthProvider(
      authService: _authService,
      firestoreService: _firestoreService,
    );
    _authProvider.init();
    _router = createAppRouter(_authProvider);
    _servicesReady = true;
  }

  @override
  void dispose() {
    if (_servicesReady) {
      _router.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startupError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          appBar: AppBar(title: const Text('Startup Error')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text(
                widget.startupError!,
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    if (!_servicesReady) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _authProvider),
        ChangeNotifierProxyProvider<AuthProvider, NotificationProvider>(
          create: (_) => NotificationProvider(),
          update: (_, auth, notifications) {
            final provider = notifications ?? NotificationProvider();
            provider.bindToUser(
              auth.userId,
              isAdmin: auth.user?.isAdmin ?? false,
            );
            return provider;
          },
        ),
        Provider<FirestoreService>.value(value: _firestoreService),
      ],
      child: MaterialApp.router(
        title: 'Price ur Plastic',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        routerConfig: _router,
      ),
    );
  }
}
