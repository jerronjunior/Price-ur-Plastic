import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/notification_model.dart';

/// Stores in-app notifications visible in the notification panel.
class NotificationProvider with ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final List<NotificationModel> _notifications = [];
  final List<NotificationModel> _userNotifications = [];
  final List<NotificationModel> _adminNotifications = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _userSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _adminSubscription;
  String? _activeUserId;
  bool _isAdmin = false;
  bool _hasUnread = false;

  List<NotificationModel> get notifications => List.unmodifiable(_notifications);
  bool get hasUnread => _hasUnread;

  void bindToUser(String? userId, {required bool isAdmin}) {
    if (_activeUserId == userId && _isAdmin == isAdmin) return;

    _userSubscription?.cancel();
    _adminSubscription?.cancel();
    _userSubscription = null;
    _adminSubscription = null;
    _activeUserId = userId;
    _isAdmin = isAdmin;

    _notifications.clear();
    _userNotifications.clear();
    _adminNotifications.clear();
    _hasUnread = false;
    notifyListeners();

    if (userId == null) return;

    _userSubscription = _firestore
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _userNotifications
        ..clear()
        ..addAll(snapshot.docs.map((doc) {
          final map = Map<String, dynamic>.from(doc.data());
          map['id'] = doc.id;
          return NotificationModel.fromMap(map);
        }));
      _mergeNotifications();
      notifyListeners();
    });

    if (isAdmin) {
      _adminSubscription = _firestore
          .collection('admin_notifications')
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen((snapshot) {
        _adminNotifications
          ..clear()
          ..addAll(snapshot.docs.map((doc) {
            final map = Map<String, dynamic>.from(doc.data());
            map['id'] = doc.id;
            return NotificationModel.fromMap(map);
          }));
        _mergeNotifications();
        notifyListeners();
      });
    }
  }

  Future<void> addRewardNotification(String reward) async {
    if (_activeUserId == null) return;

    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final notification = NotificationModel(
      id: id,
      title: 'Reward Won',
      subtitle: 'You win $reward.',
      time: _formatTime(now),
      icon: 'reward',
      color: '#4CAF50',
      isRead: false,
    );

    // Keep latest items first.
    _userNotifications.insert(0, notification);
    _mergeNotifications();
    notifyListeners();

    try {
      await _firestore
          .collection('users')
          .doc(_activeUserId)
          .collection('notifications')
          .doc(id)
          .set({
        ...notification.toMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Keep local notification if remote write fails.
    }
  }

  Future<void> markAllAsRead() async {
    if (!_hasUnread) return;

    final unreadUserIds = _userNotifications
        .where((notification) => !notification.isRead)
        .map((notification) => notification.id)
        .toList();

    if (_activeUserId != null && unreadUserIds.isNotEmpty) {
      final batch = _firestore.batch();
      for (final id in unreadUserIds) {
        final ref = _firestore
            .collection('users')
            .doc(_activeUserId)
            .collection('notifications')
            .doc(id);
        batch.update(ref, {'isRead': true});
      }
      try {
        await batch.commit();
      } catch (_) {
        return;
      }
    }

    if (_isAdmin) {
      final unreadAdminIds = _adminNotifications
          .where((notification) => !notification.isRead)
          .map((notification) => notification.id)
          .toList();
      if (unreadAdminIds.isNotEmpty) {
        final batch = _firestore.batch();
        for (final id in unreadAdminIds) {
          final ref = _firestore.collection('admin_notifications').doc(id);
          batch.update(ref, {'isRead': true});
        }
        try {
          await batch.commit();
        } catch (_) {}
      }
    }

    _userNotifications.setAll(
      0,
      _userNotifications.map(_markReadCopy),
    );
    _adminNotifications.setAll(
      0,
      _adminNotifications.map(_markReadCopy),
    );
    _mergeNotifications();
    notifyListeners();
  }

  String _formatTime(DateTime time) {
    final hour = time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _adminSubscription?.cancel();
    super.dispose();
  }

  NotificationModel _markReadCopy(NotificationModel notification) {
    if (notification.isRead) return notification;
    return NotificationModel(
      id: notification.id,
      title: notification.title,
      subtitle: notification.subtitle,
      time: notification.time,
      icon: notification.icon,
      color: notification.color,
      isRead: true,
    );
  }

  void _mergeNotifications() {
    _notifications
      ..clear()
      ..addAll([..._userNotifications, ..._adminNotifications]);
    _hasUnread = _notifications.any((notification) => !notification.isRead);
  }
}
