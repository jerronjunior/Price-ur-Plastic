import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

class StorageServiceException implements Exception {
  const StorageServiceException({required this.code, this.message});

  final String code;
  final String? message;
}

/// Service for uploading files to Firebase Storage.
class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> uploadProfileImage(String userId, File imageFile) async {
    try {
      if (!await imageFile.exists()) {
        throw const StorageServiceException(
          code: 'not-found',
          message: 'Image file not found.',
        );
      }

      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final objectPath = 'profile_images/$userId/$fileName';
      final ref = _storage.ref().child(objectPath);
      await ref.putFile(imageFile);
      return await ref.getDownloadURL();
    } on FirebaseException catch (e) {
      debugPrint('Error uploading profile image: ${e.code} ${e.message}');
      throw StorageServiceException(code: e.code, message: e.message);
    } on StorageServiceException {
      rethrow;
    } catch (e) {
      debugPrint('Unexpected error uploading profile image: $e');
      throw const StorageServiceException(
        code: 'upload-failed',
        message: 'Failed to upload profile image.',
      );
    }
  }

  Future<void> deleteProfileImage(String userId) async {
    try {
      final root = _storage.ref().child('profile_images/$userId');
      final listResult = await root.listAll();
      for (final item in listResult.items) {
        await item.delete();
      }
    } catch (e) {
      debugPrint('Error deleting profile images: $e');
    }
  }
}
