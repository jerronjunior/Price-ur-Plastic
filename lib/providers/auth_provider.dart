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
        try {
          await _loadUser(user.uid);
        } catch (_) {
          _user = UserModel(
            userId: user.uid,
            name: user.displayName ?? user.email?.split('@').first ?? 'User',
            email: user.email ?? '',
            totalPoints: 0,
            totalBottles: 0,
          );
          notifyListeners();
        }
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
      try {
        await _firestore.setUser(UserModel(
          userId: uid,
          name: name,
          email: email,
          totalPoints: 0,
          totalBottles: 0,
        ));
        await _loadUser(uid);
      } catch (_) {
        _user = UserModel(
          userId: uid,
          name: name,
          email: email,
          totalPoints: 0,
          totalBottles: 0,
        );
        notifyListeners();
      }
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthMessage(e, fallback: 'Registration failed.');
    } catch (_) {
      return 'Registration failed. Check Firebase Auth and Firestore setup.';
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
      if (cred.user != null) {
        try {
          await _loadUser(cred.user!.uid);
        } catch (_) {
          _user = UserModel(
            userId: cred.user!.uid,
            name:
                cred.user!.displayName ?? cred.user!.email?.split('@').first ?? 'User',
            email: cred.user!.email ?? '',
            totalPoints: 0,
            totalBottles: 0,
          );
          notifyListeners();
        }
      }
      return null;
    } on FirebaseAuthException catch (e) {
      return _friendlyAuthMessage(e, fallback: 'Login failed.');
    } catch (_) {
      return 'Login failed. Check Firebase Auth and Firestore setup.';
    }
  }

  String _friendlyAuthMessage(
    FirebaseAuthException e, {
    required String fallback,
  }) {
    switch (e.code) {
      case 'operation-not-allowed':
        return 'Email/password sign-in is disabled in Firebase Authentication.';
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'This email is already registered.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      default:
        return e.message ?? fallback;
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

  /// Update profile image.
  Future<void> updateProfileImage(String? imageUrl) async {
    final uid = userId;
    if (uid == null || _user == null) return;
    await _firestore.updateProfileImage(uid, imageUrl);
    _user = _user!.copyWith(profileImageUrl: imageUrl);
    notifyListeners();
  }

  /// Update total points (for spin wheel or other point changes).
  Future<void> updateTotalPoints(int points) async {
    final uid = userId;
    if (uid == null || _user == null) return;
    await _firestore.updateTotalPoints(uid, points);
    _user = _user!.copyWith(totalPoints: points);
    notifyListeners();
  }
}
