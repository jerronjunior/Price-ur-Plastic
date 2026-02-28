import 'firestore_service.dart';

/// Validates scan flow: duplicate barcode, daily limit (25), cooldown (20s).
class ScanValidationService {
  ScanValidationService(this._firestore);

  final FirestoreService _firestore;

  static const int maxBottlesPerDay = 25;
  static const int cooldownSeconds = 20;

  /// Returns null if valid; error message if invalid.
  Future<String?> validateBeforeScan(String userId) async {
    final lastTime = await _firestore.getLastRecycleTime(userId);
    if (lastTime != null) {
      final elapsed = DateTime.now().difference(lastTime).inSeconds;
      if (elapsed < cooldownSeconds) {
        return 'Please wait ${cooldownSeconds - elapsed} seconds before scanning again.';
      }
    }
    final todayCount = await _firestore.countUserBottlesToday(userId);
    if (todayCount >= maxBottlesPerDay) {
      return 'Daily limit of $maxBottlesPerDay bottles reached. Try again tomorrow.';
    }
    return null;
  }

  /// Returns null if barcode is new; error message if already recycled.
  Future<String?> validateBarcode(String barcode) async {
    final exists = await _firestore.barcodeExists(barcode);
    if (exists) return 'Bottle already recycled.';
    return null;
  }
}
