import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import '../models/recycled_bottle_model.dart';
import '../models/bin_model.dart';
import '../models/reward_config_model.dart';

/// Firestore operations for users, recycled_bottles, and bins.
class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const String _usersCollection = 'users';
  static const String _recycledBottlesCollection = 'recycled_bottles';
  static const String _binsCollection = 'bins';
  static const String _rewardConfigCollection = 'reward_config';

  String _safeBinDocId(String raw) {
    final trimmed = raw.trim();
    final cleaned = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return cleaned.isEmpty ? 'bin_${DateTime.now().millisecondsSinceEpoch}' : cleaned;
  }

  // --- Users ---

  /// Create or overwrite user document after registration.
  Future<void> setUser(UserModel user) async {
    await _firestore.collection(_usersCollection).doc(user.userId).set(
          user.toMap(),
          SetOptions(merge: true),
        );
  }

  /// Get user by ID.
  Future<UserModel?> getUser(String userId) async {
    final doc = await _firestore.collection(_usersCollection).doc(userId).get();
    if (doc.exists && doc.data() != null) {
      return UserModel.fromMap(doc.id, doc.data()!);
    }
    return null;
  }

  /// Stream user document for real-time updates.
  Stream<UserModel?> userStream(String userId) {
    return _firestore
        .collection(_usersCollection)
        .doc(userId)
        .snapshots()
        .map((doc) {
      if (doc.exists && doc.data() != null) {
        return UserModel.fromMap(doc.id, doc.data()!);
      }
      return null;
    });
  }

  /// Update user name.
  Future<void> updateUserName(String userId, String name) async {
    await _firestore.collection(_usersCollection).doc(userId).update({
      'name': name,
    });
  }

  /// Update profile fields that can be edited in profile screen.
  Future<void> updateUserProfile({
    required String userId,
    required String name,
    required String mobile,
  }) async {
    await _firestore.collection(_usersCollection).doc(userId).update({
      'name': name,
      'mobile': mobile,
    });
  }

  /// Update user profile image URL.
  Future<void> updateProfileImage(String userId, String? imageUrl) async {
    await _firestore.collection(_usersCollection).doc(userId).set({
      'profileImageUrl': imageUrl,
    }, SetOptions(merge: true));
  }

  /// Update user total points (for spin wheel and other features).
  Future<void> updateTotalPoints(String userId, int points) async {
    await _firestore.collection(_usersCollection).doc(userId).update({
      'totalPoints': points,
    });
  }

  /// Increment user points and bottles (called after successful recycle).
  Future<void> incrementUserPointsAndBottles(String userId) async {
    final ref = _firestore.collection(_usersCollection).doc(userId);
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final currentPoints = (snap.data()?['totalPoints'] as num?)?.toInt() ?? 0;
      final currentBottles =
          (snap.data()?['totalBottles'] as num?)?.toInt() ?? 0;
      tx.update(ref, {
        'totalPoints': currentPoints + 1,
        'totalBottles': currentBottles + 1,
      });
    });
  }

  // --- Recycled bottles ---

  /// Check if barcode was already recycled (each barcode can only be used once).
  Future<bool> barcodeExists(String barcode) async {
    final query = await _firestore
        .collection(_recycledBottlesCollection)
        .where('barcode', isEqualTo: barcode)
        .limit(1)
        .get();
    return query.docs.isNotEmpty;
  }

  /// Count bottles recycled by user today (for daily limit of 25).
  Future<int> countUserBottlesToday(String userId) async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final query = await _firestore
        .collection(_recycledBottlesCollection)
        .where('userId', isEqualTo: userId)
        .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('timestamp', isLessThan: Timestamp.fromDate(endOfDay))
        .get();
    return query.docs.length;
  }

  /// Get last recycle timestamp for cooldown (20 seconds).
  Future<DateTime?> getLastRecycleTime(String userId) async {
    final query = await _firestore
        .collection(_recycledBottlesCollection)
        .where('userId', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();
    if (query.docs.isEmpty) return null;
    final data = query.docs.first.data();
    final ts = data['timestamp'];
    return ts is Timestamp ? ts.toDate() : null;
  }

  /// Save recycled bottle and increment user stats.
  Future<void> saveRecycledBottle(RecycledBottleModel bottle) async {
    final batch = _firestore.batch();
    final bottleRef =
        _firestore.collection(_recycledBottlesCollection).doc();
    batch.set(bottleRef, bottle.toMap());
    final userRef = _firestore.collection(_usersCollection).doc(bottle.userId);
    final userSnap = await userRef.get();
    final currentPoints =
        (userSnap.data()?['totalPoints'] as num?)?.toInt() ?? 0;
    final currentBottles =
        (userSnap.data()?['totalBottles'] as num?)?.toInt() ?? 0;
    batch.update(userRef, {
      'totalPoints': currentPoints + 1,
      'totalBottles': currentBottles + 1,
    });
    await batch.commit();
  }

  // --- Bins ---

  /// Get bin by ID (for QR scan).
  Future<BinModel?> getBin(String binId) async {
    final idCandidate = binId.trim();
    if (idCandidate.isNotEmpty && !idCandidate.contains('/')) {
      final byIdDoc = await _firestore.collection(_binsCollection).doc(idCandidate).get();
      if (byIdDoc.exists && byIdDoc.data() != null) {
        return BinModel.fromMap(byIdDoc.id, byIdDoc.data()!);
      }
    }

    // Backstop lookup for bins where QR is stored in field instead of doc id.
    final byQr = await _firestore
        .collection(_binsCollection)
        .where('qrCode', isEqualTo: binId)
        .limit(1)
        .get();
    if (byQr.docs.isNotEmpty) {
      final doc = byQr.docs.first;
      return BinModel.fromMap(doc.id, doc.data());
    }
    return null;
  }

  /// Create bin (admin/seed use).
  Future<void> setBin(BinModel bin) async {
    final docId = _safeBinDocId(bin.binId);
    await _firestore
        .collection(_binsCollection)
        .doc(docId)
        .set({
          ...bin.toMap(),
          'binId': docId,
          'qrCode': bin.qrCode,
        }, SetOptions(merge: true));
  }

  /// Increment user points by a specific amount (for bin scans, etc).
  Future<void> incrementUserPoints(String userId, int points) async {
    final ref = _firestore.collection(_usersCollection).doc(userId);
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final currentPoints = (snap.data()?['totalPoints'] as num?)?.toInt() ?? 0;
      tx.update(ref, {
        'totalPoints': currentPoints + points,
      });
    });
  }

  /// Log a bin scan for analytics.
  Future<void> logBinScan(String userId, String binId) async {
    await _firestore.collection(_usersCollection).doc(userId).collection('bin_scans').add({
      'binId': binId,
      'timestamp': Timestamp.now(),
    });
  }

  Future<void> addAdminRewardNotification({
    required String userName,
    required String reward,
  }) async {
    final now = DateTime.now();
    await _firestore.collection('admin_notifications').add({
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
      'createdAt': FieldValue.serverTimestamp(),
      'type': 'reward_win',
    });
  }

  // --- Leaderboard ---

  /// Top 10 users by totalPoints, real-time stream (legacy, kept for compat).
  Stream<List<UserModel>> leaderboardStream() {
    return _firestore
        .collection(_usersCollection)
        .orderBy('totalPoints', descending: true)
        .limit(10)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList());
  }

  /// ALL users ordered by totalPoints descending — real-time stream.
  ///
  /// IMPORTANT: Does NOT use orderBy('totalPoints') in the Firestore query
  /// because:
  ///   1. Users registered before points were introduced have no totalPoints
  ///      field — Firestore orderBy silently skips documents missing the
  ///      ordered field, making them invisible on the leaderboard.
  ///   2. orderBy on a non-indexed field throws a requires-index error.
  ///
  /// Instead: fetch all users with no filter, sort client-side in Dart.
  /// This guarantees every registered user appears on the leaderboard.
  Stream<List<UserModel>> leaderboardStreamAll() {
    return _firestore
        .collection(_usersCollection)
        .snapshots()
        .map((snap) {
      final all = <UserModel>[];
      for (final doc in snap.docs) {
        try {
          // doc.data() returns an unmodifiable map — copy it first
          final raw = Map<String, dynamic>.from(doc.data());

          // Safely parse totalPoints — handle int, double, null, missing
          final pts = raw['totalPoints'];
          raw['totalPoints'] = pts is num ? pts.toInt() : 0;

          final bottles = raw['totalBottles'];
          raw['totalBottles'] = bottles is num ? bottles.toInt() : 0;

            final rawEmail = (raw['email'] ?? '').toString().trim();
            final emailPrefix = rawEmail.contains('@')
              ? rawEmail.split('@').first
              : rawEmail;
            final rawName = (raw['name'] ?? '').toString().trim();

            // Keep leaderboard names non-empty (important for admin users
            // created from console with blank name fields).
            raw['name'] = rawName.isNotEmpty
              ? rawName
              : (emailPrefix.isNotEmpty ? emailPrefix : 'User');
            raw['email'] = rawEmail;

          all.add(UserModel.fromMap(doc.id, raw));
        } catch (e) {
          // Skip malformed documents — never crash the whole leaderboard
          debugPrint('leaderboardStreamAll: skipping doc ${doc.id}: $e');
        }
      }
      // Sort by totalPoints descending in Dart
      all.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return all;
    });
  }

  // --- Admin: Bin Management ---

  /// Get all bins (admin view).
  Stream<List<BinModel>> getAllBinsStream() {
    return _firestore
        .collection(_binsCollection)
        .orderBy('locationName')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => BinModel.fromMap(d.id, d.data())).toList());
  }

  /// Add a new bin (admin).
  Future<void> addBin(String binId, String locationName) async {
    final qrCode = binId.trim();
    final docId = _safeBinDocId(qrCode);
    await _firestore.collection(_binsCollection).doc(docId).set({
      'binId': docId,
      'qrCode': qrCode,
      'locationName': locationName,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Update bin location (admin).
  Future<void> updateBin(String binId, String locationName) async {
    final docId = _safeBinDocId(binId);
    await _firestore.collection(_binsCollection).doc(docId).update({
      'locationName': locationName,
    });
  }

  /// Delete bin (admin).
  Future<void> deleteBin(String binId) async {
    final docId = _safeBinDocId(binId);
    await _firestore.collection(_binsCollection).doc(docId).delete();
  }

  // --- Admin: Reward Configuration ---

  /// Get reward configuration (or return default).
  Future<RewardConfigModel> getRewardConfig() async {
    final doc = await _firestore
        .collection(_rewardConfigCollection)
        .doc('default')
        .get();
    if (doc.exists && doc.data() != null) {
      return RewardConfigModel.fromMap(doc.id, doc.data()!);
    }
    // Return defaults if not configured yet
    return const RewardConfigModel(id: 'default');
  }

  /// Stream reward configuration.
  Stream<RewardConfigModel> rewardConfigStream() {
    return _firestore
        .collection(_rewardConfigCollection)
        .doc('default')
        .snapshots()
        .map((doc) {
      if (doc.exists && doc.data() != null) {
        return RewardConfigModel.fromMap(doc.id, doc.data()!);
      }
      return const RewardConfigModel(id: 'default');
    });
  }

  /// Update reward configuration (admin).
  Future<void> updateRewardConfig(RewardConfigModel config) async {
    await _firestore
        .collection(_rewardConfigCollection)
        .doc('default')
        .set(config.toMap(), SetOptions(merge: true));
  }

  /// Get total counts for admin dashboard.
  Future<Map<String, int>> getAdminStats() async {
    final usersCount = await _firestore.collection(_usersCollection).count().get();
    final binsCount = await _firestore.collection(_binsCollection).count().get();
    final bottlesCount = await _firestore.collection(_recycledBottlesCollection).count().get();
    
    return {
      'totalUsers': usersCount.count ?? 0,
      'totalBins': binsCount.count ?? 0,
      'totalBottlesRecycled': bottlesCount.count ?? 0,
    };
  }

  Stream<List<UserModel>> allUsersStream() {
    return _firestore
        .collection(_usersCollection)
        .snapshots()
        .map((snapshot) {
      final users = snapshot.docs
          .map((doc) => UserModel.fromMap(doc.id, doc.data()))
          .toList();
      users.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return users;
    });
  }
}