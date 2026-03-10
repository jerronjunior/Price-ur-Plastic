/// User profile and stats stored in Firestore.
class UserModel {
  final String userId;
  final String name;
  final String email;
  final String mobile;
  final int totalPoints;
  final int totalBottles;
  final String? profileImageUrl;
  final bool isAdmin;

  const UserModel({
    required this.userId,
    required this.name,
    required this.email,
    this.mobile = '',
    this.totalPoints = 0,
    this.totalBottles = 0,
    this.profileImageUrl,
    this.isAdmin = false,
  });

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    return UserModel(
      userId: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      mobile: map['mobile'] as String? ?? '',
      totalPoints: (map['totalPoints'] as num?)?.toInt() ?? 0,
      totalBottles: (map['totalBottles'] as num?)?.toInt() ?? 0,
      profileImageUrl: map['profileImageUrl'] as String?,
      isAdmin: map['isAdmin'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'email': email,
        'mobile': mobile,
        'totalPoints': totalPoints,
        'totalBottles': totalBottles,
        'isAdmin': isAdmin,
        if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
      };

  UserModel copyWith({
    String? name,
    String? mobile,
    int? totalPoints,
    int? totalBottles,
    String? profileImageUrl,
  }) {
    return UserModel(
      userId: userId,
      name: name ?? this.name,
      email: email,
      mobile: mobile ?? this.mobile,
      totalPoints: totalPoints ?? this.totalPoints,
      totalBottles: totalBottles ?? this.totalBottles,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
    );
  }
}
