import 'package:supabase_flutter/supabase_flutter.dart';

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

/// Handles Supabase Authentication (email/password).
class AuthService {
  final SupabaseClient _client = Supabase.instance.client;

  AppAuthUser? get currentUser => _mapUser(_client.auth.currentUser);
  String? get currentUserId => _client.auth.currentUser?.id;

  Stream<AppAuthUser?> get authStateChanges {
    return _client.auth.onAuthStateChange.map(
      (state) => _mapUser(state.session?.user ?? _client.auth.currentUser),
    );
  }

  /// Register with email and password.
  Future<AppAuthResult> registerWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
      );
      return AppAuthResult(user: _mapUser(response.user));
    } on AuthException catch (e) {
      throw AppAuthException(
          code: e.statusCode ?? 'auth_error', message: e.message);
    }
  }

  /// Sign in with email and password.
  Future<AppAuthResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return AppAuthResult(user: _mapUser(response.user));
    } on AuthException catch (e) {
      throw AppAuthException(
          code: e.statusCode ?? 'auth_error', message: e.message);
    }
  }

  /// Sign out.
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Sends a password reset email.
  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email);
    } on AuthException catch (e) {
      throw AppAuthException(
          code: e.statusCode ?? 'auth_error', message: e.message);
    }
  }

  /// Change password for the currently signed-in user.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppAuthException(code: 'user-not-found');
    }
    final email = user.email;
    if (email == null || email.isEmpty) {
      throw const AppAuthException(code: 'invalid-email');
    }

    try {
      // Verify current password before changing password.
      await _client.auth.signInWithPassword(
        email: email,
        password: currentPassword,
      );
      await _client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
    } on AuthException catch (e) {
      throw AppAuthException(
          code: e.statusCode ?? 'auth_error', message: e.message);
    }
  }

  AppAuthUser? _mapUser(User? user) {
    if (user == null) return null;
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    return AppAuthUser(
      uid: user.id,
      email: user.email,
      displayName: metadata['name']?.toString(),
    );
  }
}
