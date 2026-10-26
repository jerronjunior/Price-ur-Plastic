// lib/services/redemption_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Redeeming points for rewards.
//
// redeem() runs ONE Firestore transaction that:
//   1. re-reads the user's points and the item's CURRENT price/active flag
//   2. refuses if the item is inactive or points are insufficient
//   3. deducts the points from users/{uid}.totalPoints
//   4. creates the redemptions/{id} document
// so points can never be spent twice or go negative, even with two taps or
// two devices. firestore_rules_redemption.txt additionally makes Firestore
// reject any redemption that isn't paired with the exact matching deduction.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/redemption_models.dart';

/// Thrown with a message that is safe to show to the user.
class RedeemException implements Exception {
  RedeemException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RedemptionService {
  RedemptionService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// Abuse guard: max redemptions per user per calendar day.
  static const int maxPerDay = 3;

  // No 0/O/1/I so codes are easy to read out at a shop counter.
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  String _newCode() {
    final r = Random.secure();
    return 'PUP-${List.generate(6, (_) => _alphabet[r.nextInt(_alphabet.length)]).join()}';
  }

  /// Active catalog items, cheapest-first within sortOrder.
  /// (Sorted in memory so no composite index is needed.)
  Stream<List<RedemptionItem>> itemsStream() {
    return _db
        .collection('redemption_items')
        .where('active', isEqualTo: true)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map(RedemptionItem.fromDoc).toList();
      list.sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.pointsCost.compareTo(b.pointsCost);
      });
      return list;
    });
  }

  /// The signed-in user's redemptions, newest first.
  Stream<List<Redemption>> myRedemptionsStream() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('redemptions')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
      final list = snap.docs.map(Redemption.fromDoc).toList();
      list.sort((a, b) => (b.createdAt ?? DateTime.now())
          .compareTo(a.createdAt ?? DateTime.now()));
      return list;
    });
  }

  /// Spend points on [item]. For reloads pass [phone] and [operator].
  /// Returns the created redemption's id and (for vouchers) its code.
  Future<({String id, String? code})> redeem(
    RedemptionItem item, {
    String? phone,
    String? operator,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw RedeemException('Please sign in again.');
    if (item.isReload && (phone == null || operator == null)) {
      throw RedeemException('Enter your mobile number and operator.');
    }

    await _checkDailyLimit(user.uid);

    final userRef = _db.collection('users').doc(user.uid);
    final itemRef = _db.collection('redemption_items').doc(item.id);
    final redRef = _db.collection('redemptions').doc();
    final code = item.isReload ? null : _newCode();

    try {
      await _db.runTransaction((tx) async {
        final userSnap = await tx.get(userRef);
        final itemSnap = await tx.get(itemRef);

        final live = itemSnap.data();
        if (live == null || live['active'] != true) {
          throw RedeemException('This reward is no longer available.');
        }
        // Use the server's price, not what the screen showed.
        final cost = (live['pointsCost'] as num?)?.toInt() ?? 0;
        if (cost <= 0) throw RedeemException('This reward is unavailable.');

        final balance =
            ((userSnap.data() ?? {})['totalPoints'] as num?)?.toInt() ?? 0;
        if (balance < cost) {
          throw RedeemException(
              'Not enough points. You need ${cost - balance} more.');
        }

        final days = (live['expiryDays'] as num?)?.toInt() ?? 30;

        tx.update(userRef, {'totalPoints': balance - cost});
        tx.set(redRef, {
          'userId': user.uid,
          'userName': user.displayName ?? user.email ?? '',
          'itemId': item.id,
          'itemTitle': live['title'] ?? item.title,
          'category': live['category'] ?? item.category,
          'emoji': live['emoji'] ?? item.emoji,
          'partnerName': live['partnerName'] ?? '',
          'pointsSpent': cost,
          'status': item.isReload ? 'pending' : 'active',
          if (code != null) 'code': code,
          if (code != null)
            'expiresAt': Timestamp.fromDate(
                DateTime.now().add(Duration(days: days == 0 ? 30 : days))),
          if (phone != null) 'phone': phone,
          if (operator != null) 'operator': operator,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });
    } on RedeemException {
      rethrow;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw RedeemException(
            'Redemption is not enabled yet. Please try again later.');
      }
      throw RedeemException('Could not complete redemption. Check your connection.');
    }

    return (id: redRef.id, code: code);
  }

  Future<void> _checkDailyLimit(String uid) async {
    final start = DateTime.now();
    final midnight = DateTime(start.year, start.month, start.day);
    final snap = await _db
        .collection('redemptions')
        .where('userId', isEqualTo: uid)
        .get();
    final today = snap.docs.where((d) {
      final t = d.data()['createdAt'];
      return t is Timestamp && !t.toDate().isBefore(midnight);
    }).length;
    if (today >= maxPerDay) {
      throw RedeemException(
          'Daily limit reached ($maxPerDay redemptions). Try again tomorrow.');
    }
  }
}
