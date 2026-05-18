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
  static const String _modelVersionKey = 'model_version';
  static const String _localVersionKey = 'local_model_version';
  static const String _remoteConfigKey = 'tflite_model_version';  // set this in Firebase Remote Config
  static const String _storageModelPath= 'models/ssd_mobilenet_v{version}.tflite';

  final FirebaseRemoteConfig _remoteConfig = FirebaseRemoteConfig.instance;
  final FirebaseStorage      _storage      = FirebaseStorage.instance;

  // ── Call this on app startup ───────────────────────────────────────────────
  Future<String?> checkAndDownloadUpdate() async {
    try {
      // Fetch latest config from Firebase
      await _remoteConfig.fetchAndActivate();
      final remoteVersion = _remoteConfig.getString(_remoteConfigKey);

      if (remoteVersion.isEmpty) {
        debugPrint('[ModelUpdate] No remote version set. Using bundled model.');
        return null; // use bundled asset
      }

      final prefs        = await SharedPreferences.getInstance();
      final localVersion = prefs.getString(_localVersionKey) ?? '';

      if (localVersion == remoteVersion) {
        // Already have the latest — return path to local file
        final path = await _localModelPath(remoteVersion);
        if (await File(path).exists()) {
          debugPrint('[ModelUpdate] Model up to date: v$remoteVersion');
          return path;
        }
      }

      // New version available — download it
      debugPrint('[ModelUpdate] New model available: v$remoteVersion '
          '(local: $localVersion). Downloading…');

      final storagePath = _storageModelPath.replaceAll('{version}', remoteVersion);
      final localPath   = await _localModelPath(remoteVersion);
      final file        = File(localPath);

      await _storage.ref(storagePath).writeToFile(file);

      // Save version so we don't re-download
      await prefs.setString(_localVersionKey, remoteVersion);

      debugPrint('[ModelUpdate] Downloaded model v$remoteVersion → $localPath');
      return localPath;

    } catch (e) {
      debugPrint('[ModelUpdate] Check failed: $e. Using bundled model.');
      return null; // fall back to bundled asset — never crash
    }
  }

  // ── Delete old model versions to save storage ─────────────────────────────
  Future<void> cleanOldVersions(String currentVersion) async {
    try {
      final dir   = await getApplicationDocumentsDirectory();
      final files = dir.listSync()
          .whereType<File>()
          .where((f) => f.path.contains('ssd_mobilenet') &&
                        !f.path.contains(currentVersion));
      for (final f in files) {
        await f.delete();
        debugPrint('[ModelUpdate] Deleted old model: ${f.path}');
      }
    } catch (e) {
      debugPrint('[ModelUpdate] Cleanup error: $e');
    }
  }

  Future<String> _localModelPath(String version) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/ssd_mobilenet_v$version.tflite';
  }
}
