class NotificationModel {
  final String id;
  final String title;
  final String subtitle;
  final String time;
  final String icon; // icon name as string
  final String color; // color hex code

  NotificationModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.time,
    required this.icon,
    required this.color,
  });

  factory NotificationModel.fromMap(Map<String, dynamic> map) {
    return NotificationModel(
      id: map['id'] ?? '',
      title: map['title'] ?? '',
      subtitle: map['subtitle'] ?? '',
      time: map['time'] ?? '',
      icon: map['icon'] ?? 'info',
      color: map['color'] ?? '#9E9E9E',
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
    };
  }
}
