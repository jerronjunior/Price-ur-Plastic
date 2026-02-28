/// User profile and stats stored in Firestore.
class UserModel {
  final String userId;
  final String name;
  final String email;
  final int totalPoints;
  final int totalBottles;

  const UserModel({
    required this.userId,
    required this.name,
    required this.email,
    this.totalPoints = 0,
    this.totalBottles = 0,
  });

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    return UserModel(
      userId: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      totalPoints: (map['totalPoints'] as num?)?.toInt() ?? 0,
      totalBottles: (map['totalBottles'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'email': email,
        'totalPoints': totalPoints,
        'totalBottles': totalBottles,
      };

  UserModel copyWith({
    String? name,
    int? totalPoints,
    int? totalBottles,
  }) {
    return UserModel(
      userId: userId,
      name: name ?? this.name,
      email: email,
      totalPoints: totalPoints ?? this.totalPoints,
      totalBottles: totalBottles ?? this.totalBottles,
    );
  }
}
