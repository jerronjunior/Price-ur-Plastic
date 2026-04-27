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
import 'services/firestore_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;

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
      await Firebase.initializeApp();
    }
  } catch (e) {
    startupError =
        'Firebase initialization failed.\n\n$e\n\n'
        'Please verify Firebase setup and try running on Android.';
  }

  runApp(EcoRecycleApp(startupError: startupError));
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
      _authProvider.dispose();
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
        title: 'EcoRecycle',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        routerConfig: _router,
      ),
    );
  }
}
