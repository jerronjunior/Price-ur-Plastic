import 'package:cloud_firestore/cloud_firestore.dart';

/// Configurable reward settings stored in Firestore.
class RewardConfigModel {
  final String id;
  final int pointsPerBottle;
  final int bronzePoints;
  final int silverPoints;
  final int goldPoints;
  final int maxBottlesPerDay;
  final int cooldownSeconds;
  final DateTime? updatedAt;

  const RewardConfigModel({
    required this.id,
    this.pointsPerBottle = 1,
    this.bronzePoints = 50,
    this.silverPoints = 200,
    this.goldPoints = 500,
    this.maxBottlesPerDay = 25,
    this.cooldownSeconds = 20,
    this.updatedAt,
  });

  factory RewardConfigModel.fromMap(String id, Map<String, dynamic> map) {
    return RewardConfigModel(
      id: id,
      pointsPerBottle: (map['pointsPerBottle'] as num?)?.toInt() ?? 1,
      bronzePoints: (map['bronzePoints'] as num?)?.toInt() ?? 50,
      silverPoints: (map['silverPoints'] as num?)?.toInt() ?? 200,
      goldPoints: (map['goldPoints'] as num?)?.toInt() ?? 500,
      maxBottlesPerDay: (map['maxBottlesPerDay'] as num?)?.toInt() ?? 25,
      cooldownSeconds: (map['cooldownSeconds'] as num?)?.toInt() ?? 20,
      updatedAt: map['updatedAt'] is Timestamp
          ? (map['updatedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'pointsPerBottle': pointsPerBottle,
        'bronzePoints': bronzePoints,
        'silverPoints': silverPoints,
        'goldPoints': goldPoints,
        'maxBottlesPerDay': maxBottlesPerDay,
        'cooldownSeconds': cooldownSeconds,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  RewardConfigModel copyWith({
    int? pointsPerBottle,
    int? bronzePoints,
    int? silverPoints,
    int? goldPoints,
    int? maxBottlesPerDay,
    int? cooldownSeconds,
  }) {
    return RewardConfigModel(
      id: id,
      pointsPerBottle: pointsPerBottle ?? this.pointsPerBottle,
      bronzePoints: bronzePoints ?? this.bronzePoints,
      silverPoints: silverPoints ?? this.silverPoints,
      goldPoints: goldPoints ?? this.goldPoints,
      maxBottlesPerDay: maxBottlesPerDay ?? this.maxBottlesPerDay,
      cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
      updatedAt: DateTime.now(),
    );
  }
}
