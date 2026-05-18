// lib/services/training_data_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// Collects training data from real user interactions.
// Every confirmed bottle scan, bin scan and insertion becomes a training sample.
// Images are uploaded to Firebase Storage.
// Metadata is saved to Firestore training_samples collection.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

enum TrainingLabel {
  bottle,        // confirmed plastic bottle
  notBottle,     // user said "wrong" — not a bottle
  binRed,        // red bin (Coca-Cola / Cargills)
  binGreen,      // green bin (Keells)
  binPurple,     // purple bin (Eco Spindles)
  binUnknown,    // unrecognised bin
  insertionConfirmed, // bottle successfully inserted
}

class TrainingSample {
  final String   id;
  final String   label;
  final String   imageUrl;
  final double   modelConfidence; // what the model thought
  final bool     modelWasCorrect; // did user confirm or correct?
  final String   userId;
  final String   deviceModel;
  final DateTime timestamp;
  final bool     verified;        // admin reviewed this sample

  const TrainingSample({
    required this.id,
    required this.label,
    required this.imageUrl,
    required this.modelConfidence,
    required this.modelWasCorrect,
    required this.userId,
    required this.deviceModel,
    required this.timestamp,
    this.verified = false,
  });

  Map<String, dynamic> toMap() => {
    'label':            label,
    'imageUrl':         imageUrl,
    'modelConfidence':  modelConfidence,
    'modelWasCorrect':  modelWasCorrect,
    'userId':           userId,
    'deviceModel':      deviceModel,
    'timestamp':        Timestamp.fromDate(timestamp),
    'verified':         verified,
  };
}

class TrainingDataService {
  final FirebaseFirestore _db      = FirebaseFirestore.instance;
  final FirebaseStorage   _storage = FirebaseStorage.instance;
  final FirebaseAuth      _auth    = FirebaseAuth.instance;

  // ── Upload training image + metadata ──────────────────────────────────────
  Future<void> saveSample({
    required String    imagePath,
    required TrainingLabel label,
    required double    modelConfidence,
    required bool      modelWasCorrect,
    String?            deviceModel,
  }) async {
    try {
      final uid       = _auth.currentUser?.uid ?? 'anonymous';
      final labelStr  = label.name;
      final timestamp = DateTime.now();
      final fileName  = '${uid}_${timestamp.millisecondsSinceEpoch}.jpg';

      // Upload image to Storage: training_data/{label}/{fileName}
      final ref = _storage.ref('training_data/$labelStr/$fileName');
      await ref.putFile(File(imagePath));
      final imageUrl = await ref.getDownloadURL();

      // Save metadata to Firestore
      await _db.collection('training_samples').add({
        'label':           labelStr,
        'imageUrl':        imageUrl,
        'modelConfidence': modelConfidence,
        'modelWasCorrect': modelWasCorrect,
        'userId':          uid,
        'deviceModel':     deviceModel ?? 'unknown',
        'timestamp':       Timestamp.fromDate(timestamp),
        'verified':        false,
      });

      debugPrint('[Training] Saved sample: $labelStr '
          '(confidence: ${(modelConfidence * 100).toStringAsFixed(0)}%, '
          'correct: $modelWasCorrect)');
    } catch (e) {
      // Never crash the app for training data — it's background work
      debugPrint('[Training] Failed to save sample: $e');
    }
  }

  // ── Called when bottle scan is CONFIRMED (correct detection) ──────────────
  Future<void> onBottleConfirmed({
    required String imagePath,
    required double confidence,
  }) async {
    await saveSample(
      imagePath:        imagePath,
      label:            TrainingLabel.bottle,
      modelConfidence:  confidence,
      modelWasCorrect:  true,
    );
  }

  // ── Called when user says detection was WRONG ─────────────────────────────
  Future<void> onBottleRejectedByUser({
    required String imagePath,
    required double confidence,
  }) async {
    await saveSample(
      imagePath:        imagePath,
      label:            TrainingLabel.notBottle,
      modelConfidence:  confidence,
      modelWasCorrect:  false,
    );
  }

  // ── Called when bin color is detected and CONFIRMED ───────────────────────
  Future<void> onBinColorConfirmed({
    required String imagePath,
    required String binType,    // coca_cola, keells, eco_spindles
    required double confidence,
  }) async {
    final label = switch (binType) {
      'coca_cola' || 'cargills' => TrainingLabel.binRed,
      'keells'                  => TrainingLabel.binGreen,
      'eco_spindles'            => TrainingLabel.binPurple,
      _                         => TrainingLabel.binUnknown,
    };
    await saveSample(
      imagePath:        imagePath,
      label:            label,
      modelConfidence:  confidence,
      modelWasCorrect:  true,
    );
  }

  // ── Called when bottle is successfully INSERTED into bin ──────────────────
  Future<void> onBottleInserted({
    required String binId,
    required String binType,
  }) async {
    try {
      final uid = _auth.currentUser?.uid ?? 'anonymous';
      // Just metadata — no image needed for insertion events
      await _db.collection('training_samples').add({
        'label':     'insertion_confirmed',
        'imageUrl':  '',
        'binId':     binId,
        'binType':   binType,
        'userId':    uid,
        'timestamp': Timestamp.fromDate(DateTime.now()),
        'verified':  true,  // insertions are ground truth
      });
      debugPrint('[Training] Insertion recorded: $binType / $binId');
    } catch (e) {
      debugPrint('[Training] Insertion save failed: $e');
    }
  }

  // ── Get training stats (for admin panel) ──────────────────────────────────
  Future<Map<String, int>> getStats() async {
    try {
      final snap = await _db.collection('training_samples').get();
      final Map<String, int> counts = {};
      for (final doc in snap.docs) {
        final label = doc.data()['label'] as String? ?? 'unknown';
        counts[label] = (counts[label] ?? 0) + 1;
      }
      return counts;
    } catch (e) {
      return {};
    }
  }
}
