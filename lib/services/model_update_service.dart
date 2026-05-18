// lib/services/model_update_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Downloads updated TFLite model from Firebase Storage when a new version
// is available. Checks Remote Config for the model version on app startup.
// App uses the downloaded model instead of the bundled asset.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ModelUpdateService {
  static const String _localVersionKey = 'local_model_version';

  /// Key used in Firebase Remote Config — set a value like "2" or "1.3" there.
  static const String _remoteConfigKey = 'tflite_model_version';

  /// Path template inside Firebase Storage bucket.
  static const String _storageModelPath =
      'models/ssd_mobilenet_v{version}.tflite';

  /// Maximum download size (150 MB). Increase if your model is larger.
  static const int _maxDownloadBytes = 150 * 1024 * 1024;

  final FirebaseRemoteConfig _remoteConfig = FirebaseRemoteConfig.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // ── Call this on app startup ─────────────────────────────────────────────
  Future<String?> checkAndDownloadUpdate() async {
    try {
      // 1. Fetch the latest Remote Config values from Firebase.
      await _remoteConfig.fetchAndActivate();
      final remoteVersion = _remoteConfig.getString(_remoteConfigKey);

      if (remoteVersion.isEmpty) {
        debugPrint('[ModelUpdate] No remote version set. Using bundled model.');
        return null; // fall back to bundled asset
      }

      // 2. Check whether we already have this version cached locally.
      final prefs = await SharedPreferences.getInstance();
      final localVersion = prefs.getString(_localVersionKey) ?? '';

      if (localVersion == remoteVersion) {
        final path = await _localModelPath(remoteVersion);
        if (await File(path).exists()) {
          debugPrint('[ModelUpdate] Model is up to date: v$remoteVersion');
          return path;
        }
      }

      // 3. New version available — download it.
      debugPrint(
        '[ModelUpdate] Downloading model v$remoteVersion '
        '(was: v$localVersion)…',
      );

      final storagePath =
          _storageModelPath.replaceAll('{version}', remoteVersion);
      final localPath = await _localModelPath(remoteVersion);

      // firebase_storage ≥ v13 removed Reference.writeToFile().
      // Use getData() instead: it returns the raw bytes as Uint8List.
      final Uint8List? bytes =
          await _storage.ref(storagePath).getData(_maxDownloadBytes);

      if (bytes == null || bytes.isEmpty) {
        debugPrint('[ModelUpdate] Download returned no data. Skipping update.');
        return null;
      }

      // Write bytes to a local file.
      await File(localPath).writeAsBytes(bytes, flush: true);

      // 4. Persist the new version so we skip re-downloading next time.
      await prefs.setString(_localVersionKey, remoteVersion);

      debugPrint('[ModelUpdate] Saved model v$remoteVersion → $localPath');
      return localPath;
    } catch (e) {
      debugPrint('[ModelUpdate] Update check failed: $e. Using bundled model.');
      return null; // never crash — fall back to bundled asset
    }
  }

  // ── Delete old model files to reclaim storage space ───────────────────────
  Future<void> cleanOldVersions(String currentVersion) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final oldFiles = dir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.contains('ssd_mobilenet') &&
                !f.path.contains(currentVersion),
          );

      for (final f in oldFiles) {
        await f.delete();
        debugPrint('[ModelUpdate] Deleted old model: ${f.path}');
      }
    } catch (e) {
      debugPrint('[ModelUpdate] Cleanup error: $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Future<String> _localModelPath(String version) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/ssd_mobilenet_v$version.tflite';
  }
}
