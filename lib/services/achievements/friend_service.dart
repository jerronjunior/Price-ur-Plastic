import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FriendService {
  FriendService({FirebaseFirestore? firestore, FirebaseAuth? auth}) : _db = firestore ?? FirebaseFirestore.instance, _auth = auth ?? FirebaseAuth.instance;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  Future<void> syncFriendsCount() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    try {
      final friends = await _db.collection('users').doc(uid).collection('friends').count().get();
      await _db.collection('users').doc(uid).set({'achievementStats.friendsCount': friends.count ?? 0}, SetOptions(merge: true));
    } catch (_) {
      // Friends are optional; achievement loading must still work without the subcollection.
    }
  }
}
