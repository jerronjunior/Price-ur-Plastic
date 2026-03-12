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

  static bool _parseBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    return fallback;
  }

  static String _parseString(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    if (value is String) return value;
    return value.toString();
  }

  static int _parseInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    return UserModel(
      userId: id,
      name: _parseString(map['name']),
      email: _parseString(map['email']),
      mobile: _parseString(map['mobile']),
        totalPoints: _parseInt(map['totalPoints']),
        totalBottles: _parseInt(map['totalBottles']),
      profileImageUrl: map['profileImageUrl'] == null
          ? null
          : _parseString(map['profileImageUrl']),
      isAdmin: _parseBool(map['isAdmin']),
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
    String? email,
    String? mobile,
    int? totalPoints,
    int? totalBottles,
    String? profileImageUrl,
    bool? isAdmin,
  }) {
    return UserModel(
      userId: userId,
      name: name ?? this.name,
      email: email ?? this.email,
      mobile: mobile ?? this.mobile,
      totalPoints: totalPoints ?? this.totalPoints,
      totalBottles: totalBottles ?? this.totalBottles,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      isAdmin: isAdmin ?? this.isAdmin,
    );
  }
}
