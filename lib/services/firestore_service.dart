import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/bin_model.dart';
import '../models/bin_location_model.dart';
import '../models/recycled_bottle_model.dart';
import '../models/reward_config_model.dart';
import '../models/user_model.dart';

/// Firebase Firestore operations for users, recycled_bottles, bins, and admin.
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String _usersCollection = 'users';
  static const String _recycledBottlesCollection = 'recycled_bottles';
  static const String _binsCollection = 'bins';
  static const String _rewardConfigCollection = 'reward_config';

  String _safeBinDocId(String raw) {
    final trimmed = raw.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return cleaned.isEmpty
        ? 'bin_${DateTime.now().millisecondsSinceEpoch}'
        : cleaned;
  }

  List<String> _binLookupCandidates(String rawValue) {
    final seed = rawValue.trim();
    if (seed.isEmpty) return const [];

    final candidates = <String>{seed};

    try {
      final decoded = Uri.decodeFull(seed).trim();
      if (decoded.isNotEmpty) candidates.add(decoded);
    } catch (_) {}

    try {
      final uri = Uri.parse(seed);
      if ((uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.pathSegments.isNotEmpty) {
        candidates.add(uri.pathSegments.last.trim());
      }

      const keys = ['bin', 'binId', 'bin_id', 'id', 'code', 'qr'];
      for (final key in keys) {
        final value = uri.queryParameters[key]?.trim();
        if (value != null && value.isNotEmpty) {
          candidates.add(value);
        }
      }
    } catch (_) {}

    final separators = [':', '=', '|', ';', ','];
    for (final sep in separators) {
      if (seed.contains(sep)) {
        final tail = seed.split(sep).last.trim();
        if (tail.isNotEmpty) candidates.add(tail);
      }
    }

    final jsonLike = RegExp(
      r'"?(binId|bin_id|id|code|qr)"?\s*[:=]\s*"?([^",}\s]+)"?',
      caseSensitive: false,
    );
    for (final match in jsonLike.allMatches(seed)) {
      final value = match.group(2)?.trim();
      if (value != null && value.isNotEmpty) {
        candidates.add(value);
      }
    }

    final expanded = <String>{};
    for (final c in candidates) {
      final t = c.trim();
      if (t.isEmpty) continue;
      expanded.add(t);
      expanded.add(t.toLowerCase());
      expanded.add(t.toUpperCase());
      expanded.add(_safeBinDocId(t));
      expanded.add(_safeBinDocId(t.toLowerCase()));
      expanded.add(_safeBinDocId(t.toUpperCase()));
    }

    return expanded.where((e) => e.isNotEmpty).toList(growable: false);
  }

  Map<String, dynamic> _asMap(dynamic data) {
    return Map<String, dynamic>.from(data as Map);
  }

  Future<void> setUser(UserModel user) async {
    await _db.collection(_usersCollection).doc(user.userId).set(
      {
        'user_id': user.userId,
        ...user.toMap(),
      },
      SetOptions(merge: true),
    );
  }

  /// Bin Locations CRUD (for map features)
  Future<List<BinLocationModel>> getBinLocations() async {
    final snap = await _db.collection(_binsCollection).get();
    return snap.docs
        .map((d) => BinLocationModel.fromMap({'id': d.id, ...d.data()}))
        .where((bin) => bin.latitude != 0.0 || bin.longitude != 0.0)
        .toList(growable: false);
  }

  Stream<List<BinLocationModel>> binLocationsStream() {
    return _db.collection(_binsCollection).snapshots().map((snap) => snap.docs
        .map((d) => BinLocationModel.fromMap({'id': d.id, ...d.data()}))
        .where((bin) => bin.latitude != 0.0 || bin.longitude != 0.0)
        .toList());
  }

  Future<void> addBinLocation(BinLocationModel bin) async {
    final id = bin.id.isNotEmpty ? bin.id : _db.collection(_binsCollection).doc().id;
    await _db.collection(_binsCollection).doc(id).set({
      'binId': id,
      'qrCode': id,
      'locationName': bin.name,
      'latitude': bin.latitude,
      'longitude': bin.longitude,
      'createdAt': DateTime.now(),
    }, SetOptions(merge: true));
  }

  Future<void> updateBinLocation(BinLocationModel bin) async {
    if (bin.id.isEmpty) throw Exception('Bin id required');
    await _db.collection(_binsCollection).doc(bin.id).set({
      'locationName': bin.name,
      'latitude': bin.latitude,
      'longitude': bin.longitude,
      'binId': bin.id,
    }, SetOptions(merge: true));
  }

  Future<void> deleteBinLocation(String id) async {
    await _db.collection(_binsCollection).doc(id).delete();
  }

  Future<UserModel?> getUser(String userId) async {
    final doc = await _db.collection(_usersCollection).doc(userId).get();
    if (!doc.exists) return null;
    final map = doc.data();
    if (map == null) return null;
    return UserModel.fromMap(userId, map);
  }

  Stream<UserModel?> userStream(String userId) {
    return _db.collection(_usersCollection).doc(userId).snapshots().map((doc) {
      if (!doc.exists) return null;
      final map = doc.data();
      if (map == null) return null;
      return UserModel.fromMap(userId, map);
    });
  }

  Future<void> updateUserName(String userId, String name) async {
    await _db.collection(_usersCollection).doc(userId).set(
      {'name': name, 'user_id': userId},
      SetOptions(merge: true),
    );
  }

  Future<void> updateUserProfile({
    required String userId,
    required String name,
    required String mobile,
  }) async {
    await _db.collection(_usersCollection).doc(userId).set(
      {
        'name': name,
        'mobile': mobile,
        'user_id': userId,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> updateProfileImage(String userId, String? imageUrl) async {
    await _db.collection(_usersCollection).doc(userId).set(
      {
        'profileImageUrl': imageUrl,
        'user_id': userId,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> updateTotalPoints(String userId, int points) async {
    await _db.collection(_usersCollection).doc(userId).set(
      {
        'totalPoints': points,
        'user_id': userId,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> incrementUserPointsAndBottles(String userId) async {
    final userRef = _db.collection(_usersCollection).doc(userId);
    await userRef.set(
      {
        'user_id': userId,
        'totalPoints': FieldValue.increment(1),
        'totalBottles': FieldValue.increment(1),
      },
      SetOptions(merge: true),
    );
  }

  Future<bool> barcodeExists(String barcode) async {
    final query = await _db
        .collection(_recycledBottlesCollection)
        .where('barcode', isEqualTo: barcode)
        .limit(1)
        .get();
    return query.docs.isNotEmpty;
  }

  Future<int> countUserBottlesToday(String userId) async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final query = await _db
        .collection(_recycledBottlesCollection)
        .where('userId', isEqualTo: userId)
        .where('timestamp', isGreaterThanOrEqualTo: startOfDay)
        .where('timestamp', isLessThan: endOfDay)
        .get();
    return query.docs.length;
  }

  Future<DateTime?> getLastRecycleTime(String userId) async {
    final query = await _db
        .collection(_recycledBottlesCollection)
        .where('userId', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return null;
    final ts = query.docs.first.data()['timestamp'];
    if (ts is Timestamp) return ts.toDate();
    if (ts is String) return DateTime.tryParse(ts)?.toLocal();
    return null;
  }

  Future<void> saveRecycledBottle(RecycledBottleModel bottle) async {
    final exists = await barcodeExists(bottle.barcode);
    if (exists) {
      throw StateError('Bottle already recycled.');
    }

    final bottleRef = _db.collection(_recycledBottlesCollection).doc();
    final userRef = _db.collection(_usersCollection).doc(bottle.userId);

    await _db.runTransaction((tx) async {
      tx.set(bottleRef, {
        'id': bottleRef.id,
        'barcode': bottle.barcode,
        'userId': bottle.userId,
        'binId': bottle.binId,
        'timestamp': bottle.timestamp,
      });

      tx.set(
        userRef,
        {
          'user_id': bottle.userId,
          'totalPoints': FieldValue.increment(1),
          'totalBottles': FieldValue.increment(1),
        },
        SetOptions(merge: true),
      );
    });
  }

  Future<BinModel?> getBin(String binId) async {
    final candidates = _binLookupCandidates(binId);

    for (final candidate in candidates) {
      final byId = await _db
          .collection(_binsCollection)
          .where('binId', isEqualTo: candidate)
          .limit(1)
          .get();
      if (byId.docs.isNotEmpty) {
        final map = byId.docs.first.data();
        return BinModel.fromMap((map['binId'] ?? candidate).toString(), map);
      }
    }

    for (final candidate in candidates) {
      final byQr = await _db
          .collection(_binsCollection)
          .where('qrCode', isEqualTo: candidate)
          .limit(1)
          .get();
      if (byQr.docs.isNotEmpty) {
        final map = byQr.docs.first.data();
        final id = (map['binId'] ?? candidate).toString();
        return BinModel.fromMap(id, map);
      }
    }

    final allBins = await _db.collection(_binsCollection).limit(300).get();
    final normalizedCandidates =
        candidates.map((e) => _safeBinDocId(e).toLowerCase()).toSet();

    for (final row in allBins.docs) {
      final data = row.data();
      final docId = (data['binId'] ?? '').toString();
      final docIdNorm = _safeBinDocId(docId).toLowerCase();
      final binIdNorm =
          _safeBinDocId((data['binId'] ?? '').toString()).toLowerCase();
      final qrNorm =
          _safeBinDocId((data['qrCode'] ?? '').toString()).toLowerCase();

      if (normalizedCandidates.contains(docIdNorm) ||
          normalizedCandidates.contains(binIdNorm) ||
          normalizedCandidates.contains(qrNorm)) {
        return BinModel.fromMap(docId, data);
      }
    }

    return null;
  }

  Future<void> setBin(BinModel bin) async {
    final docId = _safeBinDocId(bin.binId);
    await _db.collection(_binsCollection).doc(docId).set(
      {
        ...bin.toMap(),
        'binId': docId,
        'qrCode': bin.qrCode,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> incrementUserPoints(String userId, int points) async {
    await _db.collection(_usersCollection).doc(userId).set(
      {
        'user_id': userId,
        'totalPoints': FieldValue.increment(points),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> logBinScan(String userId, String binId) async {
    await _db.collection('bin_scans').add({
      'userId': userId,
      'binId': binId,
      'timestamp': DateTime.now(),
    });
  }

  Future<void> addAdminRewardNotification({
    required String userName,
    required String reward,
  }) async {
    final now = DateTime.now();
    await _db.collection('admin_notifications').add({
      'title': 'User Won Reward',
      'subtitle': '$userName won $reward.',
      'time': '${now.day.toString().padLeft(2, '0')}/'
          '${now.month.toString().padLeft(2, '0')}/'
          '${now.year} '
          '${(now.hour % 12 == 0 ? 12 : now.hour % 12).toString()}:${now.minute.toString().padLeft(2, '0')} '
          '${now.hour >= 12 ? 'PM' : 'AM'}',
      'icon': 'reward',
      'color': '#FF9800',
      'isRead': false,
      'createdAt': now,
      'type': 'reward_win',
    });
  }

  Stream<List<UserModel>> leaderboardStream() {
    return _db
        .collection(_usersCollection)
        .orderBy('totalPoints', descending: true)
        .limit(10)
        .snapshots()
        .map((snap) => snap.docs.map((doc) {
              final map = doc.data();
              final id = (map['user_id'] ?? doc.id).toString();
              return UserModel.fromMap(id, map);
            }).toList());
  }

  Stream<List<UserModel>> leaderboardStreamAll() {
    return _db.collection(_usersCollection).snapshots().map((snap) {
      final all = <UserModel>[];
      for (final doc in snap.docs) {
        try {
          final raw = _normalizeLeaderboardRow(_asMap(doc.data()));
          final pts = raw['totalPoints'];
          raw['totalPoints'] = pts is num ? pts.toInt() : 0;

          final bottles = raw['totalBottles'];
          raw['totalBottles'] = bottles is num ? bottles.toInt() : 0;

          final rawEmail = (raw['email'] ?? '').toString().trim();
          final emailPrefix =
              rawEmail.contains('@') ? rawEmail.split('@').first : rawEmail;
          final rawName = (raw['name'] ?? '').toString().trim();

          raw['name'] = rawName.isNotEmpty
              ? rawName
              : (emailPrefix.isNotEmpty ? emailPrefix : 'User');
          raw['email'] = rawEmail;

          all.add(UserModel.fromMap((raw['user_id'] ?? doc.id).toString(), raw));
        } catch (_) {}
      }

      all.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return all;
    });
  }

  Map<String, dynamic> _normalizeLeaderboardRow(Map<String, dynamic> source) {
    final map = Map<String, dynamic>.from(source);

    map['user_id'] =
        (map['user_id'] ?? map['id'] ?? map['uid'] ?? '').toString();
    map['name'] =
        (map['name'] ?? map['full_name'] ?? map['username'] ?? '').toString();
    map['email'] = (map['email'] ?? '').toString();
    map['mobile'] = (map['mobile'] ?? '').toString();
    map['totalPoints'] =
        map['totalPoints'] ?? map['total_points'] ?? map['points'] ?? 0;
    map['totalBottles'] =
        map['totalBottles'] ?? map['total_bottles'] ?? map['bottles'] ?? 0;
    map['profileImageUrl'] = map['profileImageUrl'] ?? map['avatar_url'];
    map['isAdmin'] = map['isAdmin'] ?? map['is_admin'] ?? false;

    return map;
  }

  Stream<List<BinModel>> getAllBinsStream() {
    return _db
        .collection(_binsCollection)
        .orderBy('locationName')
        .snapshots()
        .map((snap) => snap.docs.map((doc) {
              final map = doc.data();
              final id = (map['binId'] ?? doc.id).toString();
              return BinModel.fromMap(id, map);
            }).toList());
  }

  Future<void> addBin(
    String binId,
    String locationName, {
    double? latitude,
    double? longitude,
  }) async {
    final qrCode = binId.trim();
    final docId = _safeBinDocId(qrCode);
    final Map<String, dynamic> payload = {
      'binId': docId,
      'qrCode': qrCode,
      'locationName': locationName,
      'createdAt': DateTime.now(),
    };

    if (latitude != null && longitude != null) {
      payload['latitude'] = latitude;
      payload['longitude'] = longitude;
    }

    await _db.collection(_binsCollection).doc(docId).set(
      payload,
      SetOptions(merge: true),
    );

  }

  Future<void> updateBin(
    String binId,
    String locationName, {
    double? latitude,
    double? longitude,
  }) async {
    final docId = _safeBinDocId(binId);
    final Map<String, dynamic> payload = {
      'locationName': locationName,
      'binId': docId,
    };

    if (latitude != null && longitude != null) {
      payload['latitude'] = latitude;
      payload['longitude'] = longitude;
    }

    await _db.collection(_binsCollection).doc(docId).set(
          payload,
          SetOptions(merge: true),
        );
  }

  Future<void> deleteBin(String binId) async {
    final docId = _safeBinDocId(binId);
    await _db.collection(_binsCollection).doc(docId).delete();
  }

  Future<RewardConfigModel> getRewardConfig() async {
    final doc =
        await _db.collection(_rewardConfigCollection).doc('default').get();
    if (doc.exists) {
      final data = doc.data();
      if (data != null) {
        return RewardConfigModel.fromMap('default', data);
      }
    }
    return const RewardConfigModel(id: 'default');
  }

  Stream<RewardConfigModel> rewardConfigStream() {
    return _db
        .collection(_rewardConfigCollection)
        .doc('default')
        .snapshots()
        .map((doc) {
      if (doc.exists && doc.data() != null) {
        return RewardConfigModel.fromMap('default', doc.data()!);
      }
      return const RewardConfigModel(id: 'default');
    });
  }

  Future<void> updateRewardConfig(RewardConfigModel config) async {
    await _db.collection(_rewardConfigCollection).doc('default').set(
          {'id': 'default', ...config.toMap()},
          SetOptions(merge: true),
        );
  }

  Future<Map<String, int>> getAdminStats() async {
    final users = await _db.collection(_usersCollection).get();
    final bins = await _db.collection(_binsCollection).get();
    final bottles = await _db.collection(_recycledBottlesCollection).get();

    return {
      'totalUsers': users.docs.length,
      'totalBins': bins.docs.length,
      'totalBottlesRecycled': bottles.docs.length,
    };
  }

  Stream<List<UserModel>> allUsersStream() {
    return _db.collection(_usersCollection).snapshots().map((snap) {
      final users = snap.docs.map((doc) {
        final map = doc.data();
        return UserModel.fromMap((map['user_id'] ?? doc.id).toString(), map);
      }).toList();
      users.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return users;
    });
  }
}
