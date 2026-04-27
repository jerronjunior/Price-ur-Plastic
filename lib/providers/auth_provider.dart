import 'dart:async';

import 'package:flutter/foundation.dart';
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
  StreamSubscription<AppAuthUser?>? _authStateSub;
  StreamSubscription<UserModel?>? _userProfileSub;
  String? _boundUserId;

  AppAuthUser? get firebaseUser => _auth.currentUser;
  String? get userId => _auth.currentUserId;
  UserModel? _user;
  UserModel? get user => _user;

  bool get isLoggedIn => userId != null;

  // Flag to show welcome message only after login
  bool _justLoggedIn = false;
  bool get justLoggedIn => _justLoggedIn;

  /// Stream for router refresh on login/logout.
  Stream<AppAuthUser?> get authStateChanges => _auth.authStateChanges;

  /// Initialize: listen to auth state and load user profile.
  void init() {
    _authStateSub?.cancel();
    _authStateSub = _auth.authStateChanges.listen((AppAuthUser? user) async {
      if (user != null) {
        _bindUserProfileStream(user.uid);
        try {
          await _loadUser(user.uid, firebaseUser: user);
        } catch (_) {
          _user = _fallbackUserFromFirebase(user);
          notifyListeners();
        }
      } else {
        _unbindUserProfileStream();
        _user = null;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _authStateSub?.cancel();
    _userProfileSub?.cancel();
    super.dispose();
  }

  void _bindUserProfileStream(String uid) {
    if (_boundUserId == uid && _userProfileSub != null) return;

    _userProfileSub?.cancel();
    _boundUserId = uid;
    _userProfileSub = _firestore.userStream(uid).listen(
      (latestUser) {
        if (latestUser == null) return;
        if (_isSameUser(_user, latestUser)) return;
        _user = latestUser;
        notifyListeners();
      },
      onError: (_) {
        // Keep existing local state on transient stream errors.
      },
    );
  }

  void _unbindUserProfileStream() {
    _userProfileSub?.cancel();
    _userProfileSub = null;
    _boundUserId = null;
  }

  bool _isSameUser(UserModel? current, UserModel next) {
    if (current == null) return false;
    return current.userId == next.userId &&
        current.name == next.name &&
        current.email == next.email &&
        current.mobile == next.mobile &&
        current.totalPoints == next.totalPoints &&
        current.totalBottles == next.totalBottles &&
        current.profileImageUrl == next.profileImageUrl &&
        current.isAdmin == next.isAdmin;
  }

  UserModel _fallbackUserFromFirebase(AppAuthUser user) {
    return UserModel(
      userId: user.uid,
      name: user.displayName ?? user.email?.split('@').first ?? 'User',
      email: user.email ?? '',
      mobile: '',
      totalPoints: 0,
      totalBottles: 0,
    );
  }

  Future<void> _loadUser(String uid, {AppAuthUser? firebaseUser}) async {
    final firestoreUser = await _firestore.getUser(uid);
    if (firestoreUser != null) {
      _user = firestoreUser;
      notifyListeners();
      return;
    }

    // If the Firestore profile doc is missing, keep UI usable and self-heal.
    final fbUser = firebaseUser ?? _auth.currentUser;
    if (fbUser != null) {
      final fallback = _fallbackUserFromFirebase(fbUser);
      _user = fallback;
      notifyListeners();
      try {
        await _firestore.setUser(fallback);
      } catch (_) {
        // Keep local fallback even if network/rules fail.
      }
      return;
    }

    _user = null;
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
          mobile: '',
          totalPoints: 0,
          totalBottles: 0,
        ));
        await _loadUser(uid, firebaseUser: cred.user);
      } catch (_) {
        _user = cred.user != null
            ? _fallbackUserFromFirebase(cred.user!)
            : UserModel(
                userId: uid,
                name: name,
                email: email,
                mobile: '',
                totalPoints: 0,
                totalBottles: 0,
              );
        notifyListeners();
      }

      // Firebase signs in automatically after registration.
      // Sign out so the user returns to login and signs in explicitly.
      await _auth.signOut();
      _user = null;
      _justLoggedIn = false;
      notifyListeners();
      return null;
    } on AppAuthException catch (e) {
      return _friendlyAuthMessage(e, fallback: 'Registration failed.');
    } catch (_) {
      return 'Registration failed. Please try again.';
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
          await _loadUser(cred.user!.uid, firebaseUser: cred.user);
        } catch (_) {
          _user = _fallbackUserFromFirebase(cred.user!);
          notifyListeners();
        }
        // Set flag to show welcome message
        _justLoggedIn = true;
      }
      return null;
    } on AppAuthException catch (e) {
      return _friendlyAuthMessage(e, fallback: 'Login failed.');
    } catch (_) {
      return 'Login failed. Please try again.';
    }
  }

  String _friendlyAuthMessage(
    AppAuthException e, {
    required String fallback,
  }) {
    final code = e.code.toLowerCase();
    final message = (e.message ?? '').toLowerCase();
    if (code.contains('invalid') && message.contains('credential')) {
      return 'Incorrect email or password.';
    }
    if (message.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (code.contains('email') && code.contains('exists')) {
      return 'This email is already registered.';
    }
    if (message.contains('already registered')) {
      return 'This email is already registered.';
    }
    if (message.contains('email not confirmed') ||
        message.contains('email not verified')) {
      return 'Please verify your email address before logging in.';
    }
    if (code.contains('weak_password') || message.contains('password')) {
      return 'Password is too weak. Use at least 6 characters.';
    }
    final isInvalidEmail = code.contains('invalid_email') ||
        code.contains('invalid-email') ||
        message.contains('invalid email') ||
        message.contains('email address is invalid') ||
        message.contains('unable to validate email address');
    if (isInvalidEmail) {
      return 'Invalid email address.';
    }
    if (message.contains('network')) {
      return 'Network error. Check your internet connection.';
    }
    if (message.contains('too many')) {
      return 'Too many attempts. Try again later.';
    }
    return e.message ?? fallback;
  }

  /// Logout.
  Future<void> logout() async {
    await _auth.signOut();
    _user = null;
    _justLoggedIn = false;
    notifyListeners();
  }

  /// Reset welcome message flag after display.
  void resetWelcomeMessage() {
    _justLoggedIn = false;
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

  /// Update editable profile fields from profile screen.
  Future<void> updateProfile({
    required String name,
    required String mobile,
  }) async {
    final uid = userId;
    if (uid == null || _user == null) return;
    await _firestore.updateUserProfile(
      userId: uid,
      name: name,
      mobile: mobile,
    );
    _user = _user!.copyWith(name: name, mobile: mobile);
    notifyListeners();
  }

  /// Update profile image.
  Future<void> updateProfileImage(String? imageUrl) async {
    final uid = userId;
    if (uid == null) return;
    await _firestore.updateProfileImage(uid, imageUrl);
    if (_user != null) {
      _user = _user!.copyWith(profileImageUrl: imageUrl);
    } else if (firebaseUser != null) {
      _user = _fallbackUserFromFirebase(firebaseUser!).copyWith(
        profileImageUrl: imageUrl,
      );
    }
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

  /// Change account password for logged-in user.
  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      await _auth.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      return null;
    } on AppAuthException catch (e) {
      return _friendlyAuthMessage(e, fallback: 'Failed to change password.');
    } catch (_) {
      return 'Failed to change password. Please try again.';
    }
  }

  /// Sends password reset email.
  Future<String?> sendPasswordResetEmail(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email);
      return null;
    } on AppAuthException catch (e) {
      return _friendlyAuthMessage(
        e,
        fallback: 'Failed to send password reset email.',
      );
    } catch (_) {
      return 'Failed to send password reset email. Please try again.';
    }
  }
}
