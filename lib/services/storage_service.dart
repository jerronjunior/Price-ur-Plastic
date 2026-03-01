import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';

/// Service for uploading files to Firebase Storage
class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Upload profile image and return the download URL
  Future<String?> uploadProfileImage(String userId, File imageFile) async {
    try {
      // Create a reference to the profile images folder
      final ref = _storage.ref().child('profile_images/$userId.jpg');
      
      // Upload the file
      final uploadTask = ref.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      
      // Wait for upload to complete
      final snapshot = await uploadTask;
      
      // Get the download URL
      final downloadUrl = await snapshot.ref.getDownloadURL();
      
      return downloadUrl;
    } catch (e) {
      print('Error uploading profile image: $e');
      return null;
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
