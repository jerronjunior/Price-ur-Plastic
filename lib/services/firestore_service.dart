import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import '../models/recycled_bottle_model.dart';
import '../models/bin_model.dart';

/// Firestore operations for users, recycled_bottles, and bins.
class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const String _usersCollection = 'users';
  static const String _recycledBottlesCollection = 'recycled_bottles';
  static const String _binsCollection = 'bins';

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
    final doc =
        await _firestore.collection(_binsCollection).doc(binId).get();
    if (doc.exists && doc.data() != null) {
      return BinModel.fromMap(doc.id, doc.data()!);
    }
    return null;
  }

  /// Create bin (admin/seed use).
  Future<void> setBin(BinModel bin) async {
    await _firestore
        .collection(_binsCollection)
        .doc(bin.binId)
        .set(bin.toMap(), SetOptions(merge: true));
  }

  // --- Leaderboard ---

  /// Top 10 users by totalPoints, real-time stream.
  Stream<List<UserModel>> leaderboardStream() {
    return _firestore
        .collection(_usersCollection)
        .orderBy('totalPoints', descending: true)
        .limit(10)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList());
  }
}
