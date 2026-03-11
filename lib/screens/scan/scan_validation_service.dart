import 'package:eco_recycle/services/firestore_service.dart';
import 'package:flutter/foundation.dart';

/// Validates whether a user is allowed to scan right now.
/// Uses only methods that actually exist on FirestoreService.
class ScanValidationService {
  ScanValidationService(this._firestore);

  final FirestoreService _firestore;

  static const int _cooldownSeconds = 20; // matches firestore_service comment
  static const int _dailyLimit = 25;       // matches firestore_service comment

  /// Returns an error message if blocked, or null if allowed to scan.
  Future<String?> validateBeforeScan(String userId) async {
    try {
      // ── Cooldown check (uses getLastRecycleTime which exists) ──────────
      final lastRecycle = await _firestore
          .getLastRecycleTime(userId)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);

      if (lastRecycle != null) {
        final secondsSince = DateTime.now().difference(lastRecycle).inSeconds;
        if (secondsSince < _cooldownSeconds) {
          final remaining = _cooldownSeconds - secondsSince;
          return 'Please wait ${remaining}s before scanning again.';
        }
      }

      // ── Daily limit check (uses countUserBottlesToday which exists) ────
      final todayCount = await _firestore
          .countUserBottlesToday(userId)
          .timeout(const Duration(seconds: 8), onTimeout: () => 0);

      if (todayCount >= _dailyLimit) {
        return 'Daily limit of $_dailyLimit scans reached.\nCome back tomorrow!';
      }

      return null; // All checks passed — allow scan
    } catch (e) {
      // Never hard-block user due to infra errors
      debugPrint('ScanValidationService.validateBeforeScan: $e');
      return null;
    }
  }

  /// Validates a barcode — checks it hasn't been recycled before.
  /// Uses barcodeExists() which exists in FirestoreService.
  Future<String?> validateBarcode(String barcode) async {
    try {
      final exists = await _firestore
          .barcodeExists(barcode)
          .timeout(const Duration(seconds: 8), onTimeout: () => false);

      if (exists) {
        return 'This bottle barcode has already been recycled.';
      }
      return null;
    } catch (e) {
      debugPrint('ScanValidationService.validateBarcode: $e');
      return null; // On error, allow scan
    }
  }
}