import 'package:flutter/foundation.dart';
import '../models/notification_model.dart';

/// Stores in-app notifications visible in the notification panel.
class NotificationProvider with ChangeNotifier {
  final List<NotificationModel> _notifications = [];
  bool _hasUnread = false;

  List<NotificationModel> get notifications => List.unmodifiable(_notifications);
  bool get hasUnread => _hasUnread;

  void addRewardNotification(String reward) {
    final now = DateTime.now();
    final notification = NotificationModel(
      id: now.microsecondsSinceEpoch.toString(),
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
}
