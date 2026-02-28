import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';

/// Holds auth state and user profile; creates/updates user doc on login/register.
class AuthProvider with ChangeNotifier {
  AuthProvider({
    required AuthService authService,
    required FirestoreService firestoreService,
  })  : _auth = authService,
        _firestore = firestoreService;

  final AuthService _auth;
  final FirestoreService _firestore;

  User? get firebaseUser => _auth.currentUser;
  String? get userId => _auth.currentUserId;
  UserModel? _user;
  UserModel? get user => _user;

  bool get isLoggedIn => userId != null;

  /// Stream for router refresh on login/logout.
  Stream<User?> get authStateChanges => _auth.authStateChanges;

  /// Initialize: listen to auth state and load user profile.
  void init() {
    _auth.authStateChanges.listen((User? user) async {
      if (user != null) {
        await _loadUser(user.uid);
      } else {
        _user = null;
        notifyListeners();
      }
    });
  }

  Future<void> _loadUser(String uid) async {
    _user = await _firestore.getUser(uid);
    notifyListeners();
  }

  /// Stream user for real-time updates (home, profile).
  Stream<UserModel?> get userStream {
    final uid = userId;
    if (uid == null) return Stream.value(null);
    return _firestore.userStream(uid);
  }

  /// Register and create user document.
  Future<String?> register({
    required String email,
    required String password,
    required String name,
  }) async {
    try {
      final cred = await _auth.registerWithEmailPassword(
        email: email,
        password: password,
      );
      final uid = cred.user?.uid;
      if (uid == null) return 'Registration failed.';
      await _firestore.setUser(UserModel(
        userId: uid,
        name: name,
        email: email,
        totalPoints: 0,
        totalBottles: 0,
      ));
      await _loadUser(uid);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Registration failed.';
    }
  }

  /// Login.
  Future<String?> login({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.signInWithEmailPassword(
        email: email,
        password: password,
      );
      if (cred.user != null) await _loadUser(cred.user!.uid);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Login failed.';
    }
  }

  /// Logout.
  Future<void> logout() async {
    await _auth.signOut();
    _user = null;
    notifyListeners();
  }

  /// Update display name.
  Future<void> updateName(String name) async {
    final uid = userId;
    if (uid == null || _user == null) return;
    await _firestore.updateUserName(uid, name);
    _user = _user!.copyWith(name: name);
    notifyListeners();
  }
}
