import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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

class EcoRecycleApp extends StatelessWidget {
  const EcoRecycleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();
    final firestoreService = FirestoreService();
    final authProvider = AuthProvider(
      authService: authService,
      firestoreService: firestoreService,
    );
    authProvider.init();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
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
        Provider<FirestoreService>.value(value: firestoreService),
      ],
      child: MaterialApp.router(
        title: 'EcoRecycle',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.theme,
        routerConfig: createAppRouter(authProvider),
      ),
    );
  }
}
