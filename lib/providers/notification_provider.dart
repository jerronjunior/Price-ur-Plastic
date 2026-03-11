import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/notification_model.dart';

/// Stores in-app notifications visible in the notification panel.
class NotificationProvider with ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final List<NotificationModel> _notifications = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  String? _activeUserId;
  bool _hasUnread = false;

  List<NotificationModel> get notifications => List.unmodifiable(_notifications);
  bool get hasUnread => _hasUnread;

  void bindToUser(String? userId) {
    if (_activeUserId == userId) return;

    _subscription?.cancel();
    _subscription = null;
    _activeUserId = userId;

    _notifications.clear();
    _hasUnread = false;
    notifyListeners();

    if (userId == null) return;

    _subscription = _firestore
        .collection('users')
        .doc(userId)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _notifications
        ..clear()
        ..addAll(snapshot.docs.map((doc) {
          final map = Map<String, dynamic>.from(doc.data());
          map['id'] = doc.id;
          return NotificationModel.fromMap(map);
        }));
      notifyListeners();
    });
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
    );

    // Keep latest items first.
    _notifications.insert(0, notification);
    _hasUnread = true;
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

  void markAllAsRead() {
    if (!_hasUnread) return;
    _hasUnread = false;
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
    _subscription?.cancel();
    super.dispose();
  }
}
