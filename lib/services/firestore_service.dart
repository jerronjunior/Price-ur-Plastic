import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_model.dart';
import '../models/recycled_bottle_model.dart';
import '../models/bin_model.dart';
import '../models/reward_config_model.dart';

/// Supabase operations for users, recycled_bottles, and bins.
class FirestoreService {
  final SupabaseClient _client = Supabase.instance.client;

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

    // Decode URL-encoded QR payloads.
    try {
      final decoded = Uri.decodeFull(seed).trim();
      if (decoded.isNotEmpty) candidates.add(decoded);
    } catch (_) {}

    // Parse URL payloads and extract common ID fields.
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

    // Handle prefixed payload formats: BIN:123, bin=123, id|123, etc.
    final separators = [':', '=', '|', ';', ','];
    for (final sep in separators) {
      if (seed.contains(sep)) {
        final tail = seed.split(sep).last.trim();
        if (tail.isNotEmpty) candidates.add(tail);
      }
    }

    // Handle JSON-like payloads: {"binId":"BIN001"}, {'id':'BIN001'}.
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

    // Add sanitized doc ID variants used by Firestore doc IDs.
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

  Stream<T> _poll<T>(Future<T> Function() loader) async* {
    yield await loader();
    yield* Stream.periodic(const Duration(seconds: 2))
        .asyncMap((_) => loader());
  }

  Map<String, dynamic> _asMap(dynamic data) {
    return Map<String, dynamic>.from(data as Map);
  }

  // --- Users ---

  /// Create or overwrite user row after registration.
  Future<void> setUser(UserModel user) async {
    await _client.from(_usersCollection).upsert(
      {
        'user_id': user.userId,
        ...user.toMap(),
      },
      onConflict: 'user_id',
    );
  }

  /// Get user by ID.
  Future<UserModel?> getUser(String userId) async {
    final data = await _client
        .from(_usersCollection)
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    if (data != null) {
      return UserModel.fromMap(userId, _asMap(data));
    }
    return null;
  }

  /// Stream user row updates.
  Stream<UserModel?> userStream(String userId) {
    return _poll(() => getUser(userId));
  }

  /// Update user name.
  Future<void> updateUserName(String userId, String name) async {
    await _client.from(_usersCollection).update({
      'name': name,
    }).eq('user_id', userId);
  }

  /// Update profile fields that can be edited in profile screen.
  Future<void> updateUserProfile({
    required String userId,
    required String name,
    required String mobile,
  }) async {
    await _client.from(_usersCollection).update({
      'name': name,
      'mobile': mobile,
    }).eq('user_id', userId);
  }

  /// Update user profile image URL.
  Future<void> updateProfileImage(String userId, String? imageUrl) async {
    await _client.from(_usersCollection).upsert({
      'user_id': userId,
      'profileImageUrl': imageUrl,
    }, onConflict: 'user_id');
  }

  /// Update user total points (for spin wheel and other features).
  Future<void> updateTotalPoints(String userId, int points) async {
    await _client.from(_usersCollection).update({
      'totalPoints': points,
    }).eq('user_id', userId);
  }

  /// Increment user points and bottles (called after successful recycle).
  Future<void> incrementUserPointsAndBottles(String userId) async {
    final user = await getUser(userId);
    final currentPoints = user?.totalPoints ?? 0;
    final currentBottles = user?.totalBottles ?? 0;
    await _client.from(_usersCollection).upsert({
      'user_id': userId,
      'totalPoints': currentPoints + 1,
      'totalBottles': currentBottles + 1,
    }, onConflict: 'user_id');
  }

  // --- Recycled bottles ---

  /// Check if barcode was already recycled (each barcode can only be used once).
  Future<bool> barcodeExists(String barcode) async {
    final query = await _client
        .from(_recycledBottlesCollection)
        .select('id')
        .eq('barcode', barcode)
        .limit(1);
    return (query as List).isNotEmpty;
  }

  /// Count bottles recycled by user today (for daily limit of 25).
  Future<int> countUserBottlesToday(String userId) async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final query = await _client
        .from(_recycledBottlesCollection)
        .select('id')
        .eq('userId', userId)
        .gte('timestamp', startOfDay.toUtc().toIso8601String())
        .lt('timestamp', endOfDay.toUtc().toIso8601String());
    return (query as List).length;
  }

  /// Get last recycle timestamp for cooldown (20 seconds).
  Future<DateTime?> getLastRecycleTime(String userId) async {
    final data = await _client
        .from(_recycledBottlesCollection)
        .select('timestamp')
        .eq('userId', userId)
        .order('timestamp', ascending: false)
        .limit(1)
        .maybeSingle();
    if (data == null) return null;
    final ts = _asMap(data)['timestamp'];
    if (ts is String) {
      return DateTime.tryParse(ts)?.toLocal();
    }
    return null;
  }

  /// Save recycled bottle and increment user stats.
  Future<void> saveRecycledBottle(RecycledBottleModel bottle) async {
    await _client.from(_recycledBottlesCollection).insert(bottle.toMap());
    await incrementUserPointsAndBottles(bottle.userId);
  }

  // --- Bins ---

  /// Get bin by ID (for QR scan).
  Future<BinModel?> getBin(String binId) async {
    final candidates = _binLookupCandidates(binId);

    for (final candidate in candidates) {
      final byId = await _client
          .from(_binsCollection)
          .select()
          .eq('binId', candidate)
          .limit(1);
      if ((byId as List).isNotEmpty) {
        final map = _asMap(byId.first);
        return BinModel.fromMap((map['binId'] ?? candidate).toString(), map);
      }
    }

    // Backstop lookup for bins where QR is stored in field instead of doc id.
    for (final candidate in candidates) {
      final byQr = await _client
          .from(_binsCollection)
          .select()
          .eq('qrCode', candidate)
          .limit(1);
      if ((byQr as List).isNotEmpty) {
        final map = _asMap(byQr.first);
        final id = (map['binId'] ?? candidate).toString();
        return BinModel.fromMap(id, map);
      }
    }

    // Final fuzzy fallback for mixed legacy data/casing/formatting differences.
    final allBins = await _client.from(_binsCollection).select().limit(300);
    final normalizedCandidates =
        candidates.map((e) => _safeBinDocId(e).toLowerCase()).toSet();

    for (final row in (allBins as List)) {
      final data = _asMap(row);
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

  /// Create bin (admin/seed use).
  Future<void> setBin(BinModel bin) async {
    final docId = _safeBinDocId(bin.binId);
    await _client.from(_binsCollection).upsert({
      ...bin.toMap(),
      'binId': docId,
      'qrCode': bin.qrCode,
    }, onConflict: 'binId');
  }

  /// Increment user points by a specific amount (for bin scans, etc).
  Future<void> incrementUserPoints(String userId, int points) async {
    final user = await getUser(userId);
    final currentPoints = user?.totalPoints ?? 0;
    await _client.from(_usersCollection).upsert({
      'user_id': userId,
      'totalPoints': currentPoints + points,
    }, onConflict: 'user_id');
  }

  /// Log a bin scan for analytics.
  Future<void> logBinScan(String userId, String binId) async {
    await _client.from('bin_scans').insert({
      'userId': userId,
      'binId': binId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> addAdminRewardNotification({
    required String userName,
    required String reward,
  }) async {
    final now = DateTime.now();
    await _client.from('admin_notifications').insert({
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
      'createdAt': now.toUtc().toIso8601String(),
      'type': 'reward_win',
    });
  }

  // --- Leaderboard ---

  /// Top 10 users by totalPoints, real-time stream (legacy, kept for compat).
  Stream<List<UserModel>> leaderboardStream() {
    return _poll(() async {
      final rows = await _client
          .from(_usersCollection)
          .select()
          .order('totalPoints', ascending: false)
          .limit(10);
      return (rows as List).map((row) {
        final map = _asMap(row);
        final id = (map['user_id'] ?? '').toString();
        return UserModel.fromMap(id, map);
      }).toList();
    });
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
    return _poll(() async {
      final rows = await _fetchLeaderboardRows();
      final all = <UserModel>[];
      for (final row in rows) {
        try {
          final raw = _normalizeLeaderboardRow(_asMap(row));

          // Safely parse totalPoints — handle int, double, null, missing
          final pts = raw['totalPoints'];
          raw['totalPoints'] = pts is num ? pts.toInt() : 0;

          final bottles = raw['totalBottles'];
          raw['totalBottles'] = bottles is num ? bottles.toInt() : 0;

          final rawEmail = (raw['email'] ?? '').toString().trim();
          final emailPrefix =
              rawEmail.contains('@') ? rawEmail.split('@').first : rawEmail;
          final rawName = (raw['name'] ?? '').toString().trim();

          // Keep leaderboard names non-empty (important for admin users
          // created from console with blank name fields).
          raw['name'] = rawName.isNotEmpty
              ? rawName
              : (emailPrefix.isNotEmpty ? emailPrefix : 'User');
          raw['email'] = rawEmail;

          all.add(UserModel.fromMap((raw['user_id'] ?? '').toString(), raw));
        } catch (e) {
          // Skip malformed documents — never crash the whole leaderboard
          debugPrint('leaderboardStreamAll: skipping row: $e');
        }
      }
      // Sort by totalPoints descending in Dart
      all.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return all;
    });
  }

  Future<List<dynamic>> _fetchLeaderboardRows() async {
    try {
      final rows = await _client.from(_usersCollection).select();
      return rows as List;
    } on PostgrestException catch (e) {
      final code = (e.code ?? '').toUpperCase();
      final message = (e.message).toLowerCase();

      final missingUsersTable =
          code == 'PGRST205' && message.contains('public.users');
      if (!missingUsersTable) rethrow;

      // Some Supabase starter setups use `profiles` instead of `users`.
      try {
        final profileRows = await _client.from('profiles').select();
        return profileRows as List;
      } on PostgrestException {
        throw StateError(
          'Database is missing the `users` table. Run supabase/schema.sql in your Supabase SQL editor.',
        );
      }
    }
  }

  Map<String, dynamic> _normalizeLeaderboardRow(Map<String, dynamic> source) {
    final map = Map<String, dynamic>.from(source);

    map['user_id'] = (map['user_id'] ?? map['id'] ?? map['uid'] ?? '').toString();
    map['name'] = (map['name'] ?? map['full_name'] ?? map['username'] ?? '').toString();
    map['email'] = (map['email'] ?? '').toString();
    map['mobile'] = (map['mobile'] ?? '').toString();
    map['totalPoints'] = map['totalPoints'] ?? map['total_points'] ?? map['points'] ?? 0;
    map['totalBottles'] = map['totalBottles'] ?? map['total_bottles'] ?? map['bottles'] ?? 0;
    map['profileImageUrl'] = map['profileImageUrl'] ?? map['avatar_url'];
    map['isAdmin'] = map['isAdmin'] ?? map['is_admin'] ?? false;

    return map;
  }

  // --- Admin: Bin Management ---

  /// Get all bins (admin view).
  Stream<List<BinModel>> getAllBinsStream() {
    return _poll(() async {
      final rows =
          await _client.from(_binsCollection).select().order('locationName');
      return (rows as List).map((row) {
        final map = _asMap(row);
        final id = (map['binId'] ?? '').toString();
        return BinModel.fromMap(id, map);
      }).toList();
    });
  }

  /// Add a new bin (admin).
  Future<void> addBin(String binId, String locationName) async {
    final qrCode = binId.trim();
    final docId = _safeBinDocId(qrCode);
    await _client.from(_binsCollection).upsert({
      'binId': docId,
      'qrCode': qrCode,
      'locationName': locationName,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'binId');
  }

  /// Update bin location (admin).
  Future<void> updateBin(String binId, String locationName) async {
    final docId = _safeBinDocId(binId);
    await _client.from(_binsCollection).update({
      'locationName': locationName,
    }).eq('binId', docId);
  }

  /// Delete bin (admin).
  Future<void> deleteBin(String binId) async {
    final docId = _safeBinDocId(binId);
    await _client.from(_binsCollection).delete().eq('binId', docId);
  }

  // --- Admin: Reward Configuration ---

  /// Get reward configuration (or return default).
  Future<RewardConfigModel> getRewardConfig() async {
    final data = await _client
        .from(_rewardConfigCollection)
        .select()
        .eq('id', 'default')
        .maybeSingle();
    if (data != null) {
      return RewardConfigModel.fromMap('default', _asMap(data));
    }
    // Return defaults if not configured yet
    return const RewardConfigModel(id: 'default');
  }

  /// Stream reward configuration.
  Stream<RewardConfigModel> rewardConfigStream() {
    return _poll(getRewardConfig);
  }

  /// Update reward configuration (admin).
  Future<void> updateRewardConfig(RewardConfigModel config) async {
    await _client.from(_rewardConfigCollection).upsert({
      'id': 'default',
      ...config.toMap(),
    }, onConflict: 'id');
  }

  /// Get total counts for admin dashboard.
  Future<Map<String, int>> getAdminStats() async {
    final users = await _client.from(_usersCollection).select('user_id');
    final bins = await _client.from(_binsCollection).select('binId');
    final bottles = await _client.from(_recycledBottlesCollection).select('id');

    return {
      'totalUsers': (users as List).length,
      'totalBins': (bins as List).length,
      'totalBottlesRecycled': (bottles as List).length,
    };
  }

  Stream<List<UserModel>> allUsersStream() {
    return _poll(() async {
      final rows = await _client.from(_usersCollection).select();
      final users = (rows as List).map((row) {
        final map = _asMap(row);
        return UserModel.fromMap((map['user_id'] ?? '').toString(), map);
      }).toList();
      users.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
      return users;
    });
  }
}
