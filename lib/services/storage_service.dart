import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Service for uploading files to Firebase Storage
class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Upload profile image and return the download URL
  Future<String> uploadProfileImage(String userId, File imageFile) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'unauthenticated',
          message: 'User must be signed in to upload profile image.',
        );
      }

      if (currentUser.uid != userId) {
        throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'permission-denied',
          message: 'Cannot upload image for another user.',
        );
      }

      // Keep profile image versions to avoid stale cache and overwrite issues.
      final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = _storage
          .ref()
          .child('profile_images')
          .child(userId)
          .child(fileName);
      
      // Upload the file
      final uploadTask = ref.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      
      // Wait for upload to complete
      final snapshot = await uploadTask;
      
      // Get the download URL
      return snapshot.ref.getDownloadURL();
    } on FirebaseException catch (e) {
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
      final ref = _storage.ref().child('profile_images/$userId.jpg');
      await ref.delete();
    } catch (e) {
      print('Error deleting profile image: $e');
    }
  }
}
