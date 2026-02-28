import 'package:firebase_auth/firebase_auth.dart';

/// Handles Firebase Authentication (email/password).
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Register with email and password.
  Future<UserCredential> registerWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  /// Sign in with email and password.
  Future<UserCredential> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  /// Sign out.
  Future<void> signOut() async {
    await _auth.signOut();
  }
}
