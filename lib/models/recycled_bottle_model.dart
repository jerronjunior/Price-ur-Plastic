import 'package:cloud_firestore/cloud_firestore.dart';

/// Single recycled bottle record in Firestore.
class RecycledBottleModel {
  final String? id;
  final String barcode;
  final String userId;
  final String binId;
  final DateTime timestamp;

  const RecycledBottleModel({
    this.id,
    required this.barcode,
    required this.userId,
    required this.binId,
    required this.timestamp,
  });

  factory RecycledBottleModel.fromMap(String id, Map<String, dynamic> map) {
    final ts = map['timestamp'];
    return RecycledBottleModel(
      id: id,
      barcode: map['barcode'] as String? ?? '',
      userId: map['userId'] as String? ?? '',
      binId: map['binId'] as String? ?? '',
      timestamp: ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'barcode': barcode,
        'userId': userId,
        'binId': binId,
        'timestamp': Timestamp.fromDate(timestamp),
      };
}
