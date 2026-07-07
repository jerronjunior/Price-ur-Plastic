import 'package:firebase_auth/firebase_auth.dart';

class AppAuthException implements Exception {
  const AppAuthException({required this.code, this.message});

  final String code;
  final String? message;
}

class AppAuthUser {
  const AppAuthUser({
    required this.uid,
    this.email,
    this.displayName,
  });

  final String uid;
  final String? email;
  final String? displayName;
}

class AppAuthResult {
  const AppAuthResult({this.user});

  final AppAuthUser? user;
}

/// Handles Firebase Authentication (email/password).
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  AppAuthUser? get currentUser => _mapUser(_auth.currentUser);
  String? get currentUserId => _auth.currentUser?.uid;

  Stream<AppAuthUser?> get authStateChanges {
    return _auth.authStateChanges().map(_mapUser);
  }

  Future<AppAuthResult> registerWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      return AppAuthResult(user: _mapUser(cred.user));
    } catch (e) {
      if (e is FirebaseAuthException) {
        throw AppAuthException(code: e.code, message: e.message);
      } else if (e is FirebaseException) {
        throw AppAuthException(code: e.code, message: e.message);
      }
      String code = 'unknown';
      String message = e.toString();
      try {
        final dynamic err = e;
        if (err.code != null) code = err.code.toString();
        if (err.message != null) message = err.message.toString();
      } catch (_) {}
      throw AppAuthException(code: code, message: message);
    }
  }

  Future<AppAuthResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return AppAuthResult(user: _mapUser(cred.user));
    } catch (e) {
      if (e is FirebaseAuthException) {
        throw AppAuthException(code: e.code, message: e.message);
      } else if (e is FirebaseException) {
        throw AppAuthException(code: e.code, message: e.message);
      }
      String code = 'unknown';
      String message = e.toString();
      try {
        final dynamic err = e;
        if (err.code != null) code = err.code.toString();
        if (err.message != null) message = err.message.toString();
      } catch (_) {}
      throw AppAuthException(code: code, message: message);
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      if (e is FirebaseAuthException) {
        throw AppAuthException(code: e.code, message: e.message);
      } else if (e is FirebaseException) {
        throw AppAuthException(code: e.code, message: e.message);
      }
      String code = 'unknown';
      String message = e.toString();
      try {
        final dynamic err = e;
        if (err.code != null) code = err.code.toString();
        if (err.message != null) message = err.message.toString();
      } catch (_) {}
      throw AppAuthException(code: code, message: message);
    }
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AppAuthException(code: 'user-not-found');
    }

    final email = user.email;
    if (email == null || email.isEmpty) {
      throw const AppAuthException(code: 'invalid-email');
    }

    try {
      final credential =
          EmailAuthProvider.credential(email: email, password: currentPassword);
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);
    } catch (e) {
      if (e is FirebaseAuthException) {
        throw AppAuthException(code: e.code, message: e.message);
      } else if (e is FirebaseException) {
        throw AppAuthException(code: e.code, message: e.message);
      }
      String code = 'unknown';
      String message = e.toString();
      try {
        final dynamic err = e;
        if (err.code != null) code = err.code.toString();
        if (err.message != null) message = err.message.toString();
      } catch (_) {}
      throw AppAuthException(code: code, message: message);
    }
  }

  AppAuthUser? _mapUser(User? user) {
    if (user == null) return null;
    return AppAuthUser(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
    );
  }
}
