import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'core/theme.dart';
import 'app/app_router.dart';
import 'providers/auth_provider.dart';
import 'providers/notification_provider.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const EcoRecycleApp());
}

class EcoRecycleApp extends StatefulWidget {
  const EcoRecycleApp({super.key});

  @override
  State<EcoRecycleApp> createState() => _EcoRecycleAppState();
}

class _EcoRecycleAppState extends State<EcoRecycleApp> {
  late final AuthService _authService;
  late final FirestoreService _firestoreService;
  late final AuthProvider _authProvider;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _firestoreService = FirestoreService();
    _authProvider = AuthProvider(
      authService: _authService,
      firestoreService: _firestoreService,
    );
    _authProvider.init();
    _router = createAppRouter(_authProvider);
  }

  @override
  void dispose() {
    _router.dispose();
    _authProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
