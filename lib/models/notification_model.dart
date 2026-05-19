import 'package:cloud_firestore/cloud_firestore.dart';

class NotificationModel {
  final String id;
  final String title;
  final String subtitle;
  final String time;
  final String icon; // icon name as string
  final String color; // color hex code
  final bool isRead;
  final DateTime? createdAt;

  NotificationModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.icon,
    required this.color,
    this.isRead = false,
    this.createdAt,
  });

  factory NotificationModel.fromMap(Map<String, dynamic> map) {
    DateTime? created;
    final rawCreated = map['createdAt'];
    if (rawCreated is Timestamp) {
      created = rawCreated.toDate();
    } else if (rawCreated is String) {
      created = DateTime.tryParse(rawCreated);
    }

    return NotificationModel(
      id: map['id'] ?? '',
      title: map['title'] ?? '',
      subtitle: map['subtitle'] ?? '',
      time: map['time'] ?? '',
      icon: map['icon'] ?? 'info',
      color: map['color'] ?? '#9E9E9E',
      isRead: map['isRead'] as bool? ?? false,
      createdAt: created,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'subtitle': subtitle,
      'time': time,
      'icon': icon,
      'color': color,
      'isRead': isRead,
      'createdAt': createdAt,
    };
  }
}
