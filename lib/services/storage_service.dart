import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
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

      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) {
        throw const StorageServiceException(
          code: 'unauthenticated',
          message: 'You must be logged in to upload a profile picture.',
        );
      }
      if (currentUid != userId) {
        throw const StorageServiceException(
          code: 'uid-mismatch',
          message: 'Profile upload blocked: user ID mismatch.',
        );
      }

      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final objectPath = 'profile_images/$userId/$fileName';
      final ref = _storage.ref().child(objectPath);
      final metadata = SettableMetadata(contentType: 'image/jpeg');

      // ── Read bytes in Dart and upload with putData(), NOT putFile() ──────
      // putFile() hands the native SDK a raw file path string, which on
      // some Android versions (especially when image_picker returns a
      // content:// or cache path) the native Firebase Storage SDK fails
      // to resolve correctly — surfacing as the unrelated-looking
      // "object-not-found" error on the FIRST upload to a brand-new path.
      //
      // Reading the bytes ourselves and using putData() avoids any native
      // file-path lookup entirely — the bytes are already in memory and
      // handed straight to the SDK.
      final bytes = await imageFile.readAsBytes();
      debugPrint('[Upload] read ${bytes.length} bytes, uploading to $objectPath');

      late final TaskSnapshot snapshot;
      try {
        final task = ref.putData(bytes, metadata);
        snapshot = await task;
        debugPrint('[Upload] putData finished — state=${snapshot.state} '
            'bytesTransferred=${snapshot.bytesTransferred}');
      } on FirebaseException catch (e) {
        debugPrint('[Upload] putData THREW: code=${e.code} message=${e.message}');
        throw StorageServiceException(
          code: 'upload-step-failed',
          message: 'Upload failed — code: ${e.code}. ${e.message ?? ""}',
        );
      }

      if (snapshot.state != TaskState.success) {
        throw StorageServiceException(
          code: 'upload-failed',
          message: 'Upload did not complete (state: ${snapshot.state}).',
        );
      }

      try {
        final url = await ref.getDownloadURL();
        debugPrint('[Upload] getDownloadURL OK — $url');
        return url;
      } on FirebaseException catch (e) {
        debugPrint('[Upload] getDownloadURL THREW: code=${e.code} message=${e.message}');
        throw StorageServiceException(
          code: 'url-step-failed',
          message: 'Could not get a download URL — code: ${e.code}. ${e.message ?? ""}',
        );
      }
    } on StorageServiceException {
      rethrow;
    } catch (e) {
      debugPrint('[Upload] Unexpected error: $e');
      throw StorageServiceException(
        code: 'upload-failed',
        message: 'Failed to upload profile image: $e',
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