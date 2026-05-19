import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/notification_model.dart';

/// Stores in-app notifications visible in the notification panel.
class NotificationProvider with ChangeNotifier {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final List<NotificationModel> _notifications = [];
  final List<NotificationModel> _userNotifications = [];
  final List<NotificationModel> _adminNotifications = [];

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _userSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _adminSub;

  String? _activeUserId;
  bool _isAdmin = false;
  bool _hasUnread = false;

  List<NotificationModel> get notifications => List.unmodifiable(_notifications);
  bool get hasUnread => _hasUnread;

  void bindToUser(String? userId, {required bool isAdmin}) {
    if (_activeUserId == userId && _isAdmin == isAdmin) return;

    _userSub?.cancel();
    _adminSub?.cancel();
    _userSub = null;
    _adminSub = null;

    _activeUserId = userId;
    _isAdmin = isAdmin;

    _notifications.clear();
    _userNotifications.clear();
    _adminNotifications.clear();
    _hasUnread = false;
    notifyListeners();

    if (userId == null) return;

    // ── Listen for user-specific notifications ──────────────────────────
    // Uses a composite query (userId + createdAt). If the required Firestore
    // index does not exist yet, the SDK throws an error whose message
    // contains a link to create it. We log that link so devs can click it.
    _userSub = _db
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen(
      (snapshot) {
        _userNotifications
          ..clear()
          ..addAll(snapshot.docs.map((doc) {
            final data = doc.data();
            return NotificationModel.fromMap({
              'id': doc.id,
              ...data,
            });
          }));
        _mergeNotifications();
        notifyListeners();
      },
      onError: (Object error) {
        // ── Index-missing errors contain a URL to create the index ──
        debugPrint(
          '[NotificationProvider] User notifications stream error: $error',
        );
        // Fallback: fetch without ordering so the user still sees messages
        _fetchUserNotificationsFallback(userId);
      },
    );

    if (_isAdmin) {
      _adminSub = _db
          .collection('admin_notifications')
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen(
        (snapshot) {
          _adminNotifications
            ..clear()
            ..addAll(snapshot.docs.map((doc) {
              final data = doc.data();
              return NotificationModel.fromMap({
                'id': doc.id,
                ...data,
              });
            }));
          _mergeNotifications();
          notifyListeners();
        },
        onError: (Object error) {
          debugPrint(
            '[NotificationProvider] Admin notifications stream error: $error',
          );
        },
      );
    }
  }

  /// Fallback when the composite index (userId + createdAt) hasn't been
  /// created yet. Fetches user notifications without ordering so the user
  /// still sees their messages immediately.
  Future<void> _fetchUserNotificationsFallback(String userId) async {
    try {
      final snapshot = await _db
          .collection('notifications')
          .where('userId', isEqualTo: userId)
          .get();

      _userNotifications
        ..clear()
        ..addAll(snapshot.docs.map((doc) {
          final data = doc.data();
          return NotificationModel.fromMap({
            'id': doc.id,
            ...data,
          });
        }));

      // Sort client-side since we can't use orderBy without the index
      _userNotifications.sort((a, b) {
        // Newest first — fallback to id comparison if time is equal
        return b.time.compareTo(a.time);
      });

      _mergeNotifications();
      notifyListeners();

      debugPrint(
        '[NotificationProvider] Fallback loaded ${_userNotifications.length} '
        'notification(s) for user $userId',
      );
    } catch (e) {
      debugPrint('[NotificationProvider] Fallback fetch also failed: $e');
    }
  }

  Future<void> addRewardNotification(String reward) async {
    if (_activeUserId == null) return;

    final now = DateTime.now();
    final notification = NotificationModel(
      id: '',
      title: 'Reward Won',
      subtitle: 'You win $reward.',
      time: _formatTime(now),
      icon: 'reward',
      color: '#4CAF50',
      isRead: false,
    );

    try {
      await _db.collection('notifications').add({
        'userId': _activeUserId,
        ...notification.toMap(),
        'createdAt': now,
      });
    } catch (_) {
      // Keep UI stable even if write fails.
    }
  }

  Future<void> markAllAsRead() async {
    if (!_hasUnread) return;

    final batch = _db.batch();

    if (_activeUserId != null) {
      final userUnread = await _db
          .collection('notifications')
          .where('userId', isEqualTo: _activeUserId)
          .where('isRead', isEqualTo: false)
          .get();
      for (final doc in userUnread.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
    }

    if (_isAdmin) {
      final adminUnread = await _db
          .collection('admin_notifications')
          .where('isRead', isEqualTo: false)
          .get();
      for (final doc in adminUnread.docs) {
        batch.update(doc.reference, {'isRead': true});
      }
    }

    await batch.commit();
  }

  Future<void> markAsRead(String notificationId) async {
    try {
      if (_activeUserId != null) {
        final userQuery = await _db
            .collection('notifications')
            .where('userId', isEqualTo: _activeUserId)
            .where('id', isEqualTo: notificationId)
            .limit(1)
            .get();

        if (userQuery.docs.isNotEmpty) {
          await userQuery.docs.first.reference.update({'isRead': true});
          return;
        }
      }

      if (_isAdmin) {
        final adminQuery = await _db
            .collection('admin_notifications')
            .where('id', isEqualTo: notificationId)
            .limit(1)
            .get();

        if (adminQuery.docs.isNotEmpty) {
          await adminQuery.docs.first.reference.update({'isRead': true});
        }
      }
    } catch (e) {
      debugPrint('Error marking notification as read: $e');
    }
  }

  String _formatTime(DateTime time) {
    final hour =
        time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  void _mergeNotifications() {
    _notifications
      ..clear()
      ..addAll([..._userNotifications, ..._adminNotifications]);

    // Ensure they are sorted by date (newest first)
    _notifications.sort((a, b) {
      if (a.createdAt != null && b.createdAt != null) {
        return b.createdAt!.compareTo(a.createdAt!);
      }
      // Fallback to sorting by formatted time string or ID if date is missing
      return b.time.compareTo(a.time);
    });

    _hasUnread = _notifications.any((notification) => !notification.isRead);
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _adminSub?.cancel();
    super.dispose();
  }
}
