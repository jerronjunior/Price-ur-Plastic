import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/notification_model.dart';

/// Stores in-app notifications visible in the notification panel.
class NotificationProvider with ChangeNotifier {
  final SupabaseClient _client = Supabase.instance.client;
  final List<NotificationModel> _notifications = [];
  final List<NotificationModel> _userNotifications = [];
  final List<NotificationModel> _adminNotifications = [];
  Timer? _pollingTimer;
  String? _activeUserId;
  bool _isAdmin = false;
  bool _hasUnread = false;

  List<NotificationModel> get notifications =>
      List.unmodifiable(_notifications);
  bool get hasUnread => _hasUnread;

  void bindToUser(String? userId, {required bool isAdmin}) {
    if (_activeUserId == userId && _isAdmin == isAdmin) return;

    _pollingTimer?.cancel();
    _pollingTimer = null;
    _activeUserId = userId;
    _isAdmin = isAdmin;

    _notifications.clear();
    _userNotifications.clear();
    _adminNotifications.clear();
    _hasUnread = false;
    notifyListeners();

    if (userId == null) return;

    _refreshNotifications();
    _pollingTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshNotifications(),
    );
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
      await _client.from('notifications').insert({
        'id': id,
        'userId': _activeUserId,
        ...notification.toMap(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
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
      try {
        await _client
            .from('notifications')
            .update({'isRead': true})
            .eq('userId', _activeUserId!)
            .inFilter('id', unreadUserIds);
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
        try {
          await _client
              .from('admin_notifications')
              .update({'isRead': true}).inFilter('id', unreadAdminIds);
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
    final hour =
        time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
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

  Future<void> _refreshNotifications() async {
    if (_activeUserId == null) return;

    try {
      final userRows = await _client
          .from('notifications')
          .select()
          .eq('userId', _activeUserId!)
          .order('createdAt', ascending: false);
      _userNotifications
        ..clear()
        ..addAll((userRows as List).map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return NotificationModel.fromMap(map);
        }));

      if (_isAdmin) {
        final adminRows = await _client
            .from('admin_notifications')
            .select()
            .order('createdAt', ascending: false);
        _adminNotifications
          ..clear()
          ..addAll((adminRows as List).map((row) {
            final map = Map<String, dynamic>.from(row as Map);
            return NotificationModel.fromMap(map);
          }));
      } else {
        _adminNotifications.clear();
      }

      _mergeNotifications();
      notifyListeners();
    } catch (_) {
      // Keep last fetched notifications when network reads fail.
    }
  }
}
