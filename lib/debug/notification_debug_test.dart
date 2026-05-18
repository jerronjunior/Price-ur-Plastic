// ─────────────────────────────────────────────────────────────────────────────
// TEMPORARY DEBUG FILE
// Add this function call inside your home screen or profile screen initState:
//   NotificationDebugTest.run(context);
//
// It directly reads Firestore and prints exactly what happens.
// DELETE THIS FILE after the issue is fixed.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class NotificationDebugTest {
  static Future<void> run(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    debugPrint('╔══════════════════════════════════════════');
    debugPrint('║ NOTIFICATION DEBUG TEST');
    debugPrint('║ Current Firebase Auth UID: $uid');

    if (uid == null) {
      debugPrint('║ ❌ NOT LOGGED IN — uid is null');
      debugPrint('╚══════════════════════════════════════════');
      return;
    }

    final db = FirebaseFirestore.instance;

    // Test 1: Can we read the notifications collection at all?
    try {
      debugPrint('║ Test 1: Reading all notifications (no filter)...');
      final all = await db.collection('notifications').limit(3).get();
      debugPrint('║ ✅ Can read collection. Total (first 3): ${all.docs.length}');
      for (final d in all.docs) {
        debugPrint('║   doc=${d.id} userId=${d.data()['userId']} title=${d.data()['title']}');
      }
    } catch (e) {
      debugPrint('║ ❌ Cannot read collection: $e');
    }

    // Test 2: Can we filter by userId?
    try {
      debugPrint('║ Test 2: Reading notifications WHERE userId == $uid...');
      final mine = await db
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .get();
      debugPrint('║ ✅ Found ${mine.docs.length} notifications for this user');
      for (final d in mine.docs) {
        debugPrint('║   title=${d.data()['title']} createdAt=${d.data()['createdAt']}');
      }
      if (mine.docs.isEmpty) {
        debugPrint('║ ⚠️  Zero docs found. Check:');
        debugPrint('║    1. Web admin sent to correct userId: $uid');
        debugPrint('║    2. Check Firestore Console → notifications → userId field matches above UID');
      }
    } catch (e) {
      debugPrint('║ ❌ Filter query failed: $e');
      if (e.toString().contains('permission')) {
        debugPrint('║ → FIX: Firestore rules blocking. Update rules:');
        debugPrint('║   match /notifications/{id} { allow list: if request.auth != null; }');
      }
      if (e.toString().contains('index') || e.toString().contains('precondition')) {
        debugPrint('║ → FIX: Missing composite index. Create in Firebase Console:');
        debugPrint('║   Collection: notifications');
        debugPrint('║   Fields: userId ASC, createdAt DESC');
      }
    }

    debugPrint('╚══════════════════════════════════════════');
  }
}
