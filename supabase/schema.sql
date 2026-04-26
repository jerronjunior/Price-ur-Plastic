import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_model.dart';

// ══════════════════════════════════════════════════════════════════════════════
// SupabaseService  —  drop-in replacement for FirestoreService
//
// YOUR SCHEMA columns (from schema.sql):
//   users: user_id, name, email, mobile, "totalPoints", "totalBottles",
//          "profileImageUrl", "isAdmin", "createdAt"
//   bins:  "binId", "qrCode", "locationName", "createdAt"
//   recycled_bottles: id, barcode, "userId", "binId", "timestamp"
//   notifications: id, "userId", title, subtitle, time, icon, color, "isRead"
//   reward_config: id, "pointsPerBottle", "bronzePoints", "silverPoints",
//                  "goldPoints", "maxBottlesPerDay", "cooldownSeconds",
//                  "wheelGifts", "updatedAt"
// ══════════════════════════════════════════════════════════════════════════════

class SupabaseService {
  final _client = Supabase.instance.client;

  String? get _uid => _client.auth.currentUser?.id;

  // ── UserModel mapper ────────────────────────────────────────────────────────
  // Maps a Supabase row (Map) → UserModel.
  // Column names match schema.sql exactly (quoted camelCase preserved).
  static UserModel _toUser(Map<String, dynamic> row) {
    return UserModel(
      userId:          row['user_id']         as String? ?? '',
      name:            row['name']            as String? ?? '',
      email:           row['email']           as String? ?? '',
      mobile:          row['mobile']          as String? ?? '',
      totalPoints:     row['totalPoints']     as int?    ?? 0,
      totalBottles:    row['totalBottles']    as int?    ?? 0,
      profileImageUrl: row['profileImageUrl'] as String?,
      isAdmin:         row['isAdmin']         as bool?   ?? false,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LEADERBOARD
  // ══════════════════════════════════════════════════════════════════════════

  // Used by LeaderboardScreen — replaces firestore.leaderboardStreamAll()
  // Supabase Realtime streams re-emit on any INSERT / UPDATE / DELETE.
  Stream<List<UserModel>> leaderboardStreamAll() {
    return _client
        .from('users')
        .stream(primaryKey: ['user_id'])
        .order('totalPoints', ascending: false)
        .map((rows) => rows.map(_toUser).toList());
  }

  // One-shot fetch (for non-stream contexts)
  Future<List<UserModel>> getLeaderboard({int limit = 100}) async {
    final rows = await _client
        .from('users')
        .select('user_id, name, email, "totalPoints", "totalBottles", "profileImageUrl"')
        .order('totalPoints', ascending: false)
        .limit(limit);
    return (rows as List).map((r) => _toUser(r as Map<String, dynamic>)).toList();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // USER PROFILE
  // ══════════════════════════════════════════════════════════════════════════

  Future<UserModel?> getUser(String userId) async {
    final row = await _client
        .from('users')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return row == null ? null : _toUser(row);
  }

  // Called after sign-up to create the profile row
  Future<void> createUser(UserModel user) async {
    await _client.from('users').upsert({
      'user_id':         user.userId,
      'name':            user.name,
      'email':           user.email,
      'mobile':          user.mobile,
      'totalPoints':     user.totalPoints,
      'totalBottles':    user.totalBottles,
      'profileImageUrl': user.profileImageUrl,
      'isAdmin':         user.isAdmin,
    });
  }

  Future<void> updateUser(UserModel user) async {
    await _client.from('users').update({
      'name':            user.name,
      'email':           user.email,
      'mobile':          user.mobile,
      'profileImageUrl': user.profileImageUrl,
    }).eq('user_id', user.userId);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BOTTLE RECORDING  (atomic increment via RPC)
  // ══════════════════════════════════════════════════════════════════════════

  // Call this when a bottle is confirmed inserted.
  // Runs the SQL function below atomically — no race conditions.
  //
  // SQL to run in Supabase SQL editor:
  //
  //   create or replace function record_bottle(
  //     p_user_id text, p_bin_id text, p_barcode text, p_points int
  //   ) returns void language plpgsql security definer as $$
  //   begin
  //     insert into recycled_bottles (barcode, "userId", "binId")
  //     values (p_barcode, p_user_id, p_bin_id)
  //     on conflict (barcode) do nothing;
  //
  //     if found then
  //       update users
  //       set "totalBottles" = "totalBottles" + 1,
  //           "totalPoints"  = "totalPoints"  + p_points
  //       where user_id = p_user_id;
  //     end if;
  //   end;
  //   $$;
  Future<void> recordBottle({
    required String userId,
    required String binId,
    required String barcode,
    required int pointsPerBottle,
  }) async {
    await _client.rpc('record_bottle', params: {
      'p_user_id': userId,
      'p_bin_id':  binId,
      'p_barcode': barcode,
      'p_points':  pointsPerBottle,
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BINS
  // ══════════════════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>?> getBin(String binId) async {
    return await _client
        .from('bins')
        .select()
        .eq('binId', binId)
        .maybeSingle();
  }

  Future<void> setBin({
    required String binId,
    required String qrCode,
    required String locationName,
  }) async {
    await _client.from('bins').upsert({
      'binId':        binId,
      'qrCode':       qrCode,
      'locationName': locationName,
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  // REWARD CONFIG
  // ══════════════════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>?> getRewardConfig() async {
    return await _client
        .from('reward_config')
        .select()
        .eq('id', 'default')
        .maybeSingle();
  }

  Stream<Map<String, dynamic>?> rewardConfigStream() {
    return _client
        .from('reward_config')
        .stream(primaryKey: ['id'])
        .eq('id', 'default')
        .map((rows) => rows.isNotEmpty ? rows.first : null);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NOTIFICATIONS
  // ══════════════════════════════════════════════════════════════════════════

  Stream<List<Map<String, dynamic>>> notificationsStream(String userId) {
    return _client
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('userId', userId)
        .order('createdAt', ascending: false)
        .map((rows) => List<Map<String, dynamic>>.from(rows));
  }

  Future<void> markNotificationRead(String notificationId) async {
    await _client
        .from('notifications')
        .update({'isRead': true})
        .eq('id', notificationId);
  }

  Future<void> markAllNotificationsRead(String userId) async {
    await _client
        .from('notifications')
        .update({'isRead': true})
        .eq('userId', userId)
        .eq('isRead', false);
  }
}