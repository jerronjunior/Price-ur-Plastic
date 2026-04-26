import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StorageServiceException implements Exception {
  const StorageServiceException({required this.code, this.message});

  final String code;
  final String? message;
}

/// Service for uploading files to Supabase Storage.
class StorageService {
  final SupabaseClient _client = Supabase.instance.client;
  static const String _bucket = 'profile-images';

  /// Upload profile image and return the download URL
  Future<String> uploadProfileImage(String userId, File imageFile) async {
    try {
      final currentUser = _client.auth.currentUser;
      if (currentUser == null) {
        throw const StorageServiceException(
          code: 'unauthenticated',
          message: 'User must be signed in to upload profile image.',
        );
      }

      if (currentUser.id != userId) {
        throw const StorageServiceException(
          code: 'permission-denied',
          message: 'Cannot upload image for another user.',
        );
      }

      // Keep profile image versions to avoid stale cache and overwrite issues.
      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final objectPath = 'profile_images/$userId/$fileName';

      // Upload the file
      final bytes = await imageFile.readAsBytes();
      await _client.storage.from(_bucket).uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      // Get the download URL
      return _client.storage.from(_bucket).getPublicUrl(objectPath);
    } on StorageException catch (e) {
      debugPrint('Error uploading profile image: ${e.statusCode} ${e.message}');
      throw StorageServiceException(
        code: e.statusCode ?? 'storage_error',
        message: e.message,
      );
    } on StorageServiceException catch (e) {
      debugPrint('Error uploading profile image: ${e.code} ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Unexpected error uploading profile image: $e');
      throw Exception('Failed to upload profile image.');
    }
  }

  /// Delete profile image from storage
  Future<void> deleteProfileImage(String userId) async {
    try {
      await _client.storage.from(_bucket).remove([
        'profile_images/$userId.jpg',
      ]);
    } catch (e) {
      print('Error deleting profile image: $e');
    }
  }
}
