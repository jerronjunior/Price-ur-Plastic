// lib/models/redemption_models.dart
// ─────────────────────────────────────────────────────────────────────────────
// Firestore shapes for the redemption feature.
//
//   redemption_items/{id}   – catalog, managed from the admin website
//   redemptions/{id}        – one document per redemption a user makes
//
// category:
//   'reload'  – mobile airtime top-up. Created as status 'pending'; an admin
//               tops the number up and marks it 'completed' (or 'rejected',
//               which refunds the points).
//   'voucher' – shop voucher (ice cream, snacks…). Created as status 'active'
//               with a single-use code; the shop / admin marks it 'used'.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:cloud_firestore/cloud_firestore.dart';

const String kCategoryReload = 'reload';
const String kCategoryVoucher = 'voucher';

DateTime? _toDate(dynamic v) => v is Timestamp ? v.toDate() : null;
int _toInt(dynamic v) => v is num ? v.toInt() : 0;

class RedemptionItem {
  const RedemptionItem({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.pointsCost,
    required this.valueLabel,
    required this.partnerName,
    required this.emoji,
    required this.active,
    required this.expiryDays,
    required this.sortOrder,
  });

  final String id;
  final String title;        // "Rs. 100 Mobile Reload" / "Ice Cream Cone"
  final String description;
  final String category;     // 'reload' | 'voucher'
  final int pointsCost;
  final String valueLabel;   // "Rs. 100"
  final String partnerName;  // shop name, empty for reloads
  final String emoji;        // "📱" / "🍦"
  final bool active;
  final int expiryDays;      // voucher validity
  final int sortOrder;

  bool get isReload => category == kCategoryReload;

  factory RedemptionItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RedemptionItem(
      id: doc.id,
      title: (d['title'] ?? '') as String,
      description: (d['description'] ?? '') as String,
      category: (d['category'] ?? kCategoryVoucher) as String,
      pointsCost: _toInt(d['pointsCost']),
      valueLabel: (d['valueLabel'] ?? '') as String,
      partnerName: (d['partnerName'] ?? '') as String,
      emoji: (d['emoji'] ?? '🎁') as String,
      active: d['active'] == true,
      expiryDays: _toInt(d['expiryDays']) == 0 ? 30 : _toInt(d['expiryDays']),
      sortOrder: _toInt(d['sortOrder']),
    );
  }
}

class Redemption {
  const Redemption({
    required this.id,
    required this.userId,
    required this.itemId,
    required this.itemTitle,
    required this.category,
    required this.pointsSpent,
    required this.status,
    required this.emoji,
    this.code,
    this.phone,
    this.operator,
    this.partnerName,
    this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String userId;
  final String itemId;
  final String itemTitle;
  final String category;
  final int pointsSpent;
  final String status; // pending | active | completed | used | rejected | expired
  final String emoji;
  final String? code;
  final String? phone;
  final String? operator;
  final String? partnerName;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get isReload => category == kCategoryReload;

  /// An unused voucher past its expiry date.
  bool get isExpired =>
      status == 'active' && expiresAt != null && expiresAt!.isBefore(DateTime.now());

  factory Redemption.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return Redemption(
      id: doc.id,
      userId: (d['userId'] ?? '') as String,
      itemId: (d['itemId'] ?? '') as String,
      itemTitle: (d['itemTitle'] ?? '') as String,
      category: (d['category'] ?? kCategoryVoucher) as String,
      pointsSpent: _toInt(d['pointsSpent']),
      status: (d['status'] ?? 'pending') as String,
      emoji: (d['emoji'] ?? '🎁') as String,
      code: d['code'] as String?,
      phone: d['phone'] as String?,
      operator: d['operator'] as String?,
      partnerName: d['partnerName'] as String?,
      createdAt: _toDate(d['createdAt']),
      expiresAt: _toDate(d['expiresAt']),
    );
  }
}
