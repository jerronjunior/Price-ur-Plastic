import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'core/theme.dart';
import 'app/app_router.dart';
import 'providers/auth_provider.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EcoRecycleBootstrap());
}

class EcoRecycleBootstrap extends StatelessWidget {
  const EcoRecycleBootstrap({super.key});

  Future<void> _initializeFirebase() {
    return Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initializeFirebase(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.theme,
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.theme,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Startup error:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        return const EcoRecycleApp();
      },
    );
  }
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
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: _authProvider),
        Provider<FirestoreService>.value(value: _firestoreService),
      ],
      child: MaterialApp.router(
        title: 'EcoRecycle',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        routerConfig: createAppRouter(_authProvider),
      ),
    );
  }
}
