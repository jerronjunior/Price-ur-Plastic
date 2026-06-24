import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../services/bottle_counting_service.dart';

enum DepositState {
  idle,
  detected,    // Bottle detected
  approaching, // Bottle approaching bin
  entering,    // Bottle entering bin
  deposited    // Bottle deposited successfully
}

class BottleDepositTracker {
  DepositState state = DepositState.idle;
  
  // The bounding box of the slot, normalized 0.0 to 1.0
  double slotLeft = 0.0;
  double slotTop = 0.0;
  double slotWidth = 0.0;
  double slotHeight = 0.0;
  
  double _lastBottleCenterY = 0.0;
  int _missingFrames = 0;
  int _intersectingFrames = 0;
  
  final VoidCallback onDeposited;
  
  BottleDepositTracker({required this.onDeposited});

  void reset() {
    state = DepositState.idle;
    _lastBottleCenterY = 0.0;
    _missingFrames = 0;
    _intersectingFrames = 0;
    debugPrint("BottleDepositTracker: Resetting state to idle.");
  }

  void updateSlotRegion({required double left, required double top, required double width, required double height}) {
    slotLeft = left;
    slotTop = top;
    slotWidth = width;
    slotHeight = height;
  }

  void processDetections(List<DetectedBottle> detections) {
    // Find the most confident bottle
    DetectedBottle? bestBottle;
    if (detections.isNotEmpty) {
      bestBottle = detections.first;
    }

    switch (state) {
      case DepositState.idle:
        if (bestBottle != null) {
          // To start a deposit sequence, the bottle must not be completely inside the slot already
          // This prevents false triggers immediately on page load when a bottle happens to be in frame.
          if (!_isIntersecting(bestBottle) && bestBottle.centerY < slotTop + (slotHeight / 2)) {
            state = DepositState.detected;
            _lastBottleCenterY = bestBottle.centerY;
            _missingFrames = 0;
            _intersectingFrames = 0;
            debugPrint("STAGE 1: Bottle detected outside bin (Y: ${bestBottle.centerY.toStringAsFixed(2)})");
          }
        }
        break;

      case DepositState.detected:
        if (bestBottle != null) {
          // Check for deliberate downward movement (at least 5% of screen)
          if (bestBottle.centerY > _lastBottleCenterY + 0.05) {
            state = DepositState.approaching;
            debugPrint("STAGE 2: Bottle approaching bin (Y: ${bestBottle.centerY.toStringAsFixed(2)})");
          }
          
          if (bestBottle.centerY > _lastBottleCenterY) {
            _lastBottleCenterY = bestBottle.centerY;
          }
          
          _missingFrames = 0;
          if (_isIntersecting(bestBottle)) {
            // If it abruptly intersects without enough approaching frames
            state = DepositState.entering;
            debugPrint("STAGE 3: Bottle entering bin directly");
          }
        } else {
          _missingFrames++;
          if (_missingFrames > 10) reset();
        }
        break;

      case DepositState.approaching:
        if (bestBottle != null) {
          if (bestBottle.centerY > _lastBottleCenterY) {
            _lastBottleCenterY = bestBottle.centerY;
          }
          _missingFrames = 0;
          
          // Check if intersecting with slot
          if (_isIntersecting(bestBottle)) {
            state = DepositState.entering;
            debugPrint("STAGE 3: Bottle entering bin");
          }
        } else {
          _missingFrames++;
          if (_missingFrames > 10) reset();
        }
        break;

      case DepositState.entering:
        if (bestBottle != null) {
          if (bestBottle.centerY > _lastBottleCenterY) {
            _lastBottleCenterY = bestBottle.centerY;
          }
          _missingFrames = 0;
          
          if (_isIntersecting(bestBottle)) {
            _intersectingFrames++;
          }
        } else {
          _missingFrames++;
          // If the bottle disappears after entering and was seen intersecting for at least a couple of frames
          if (_missingFrames > 3) {
            if (_intersectingFrames > 0) {
              state = DepositState.deposited;
              debugPrint("STAGE 4: Bottle deposited successfully (lost inside bin)");
              onDeposited();
              debugPrint("STAGE 5: Counter updated");
            } else {
              debugPrint("Tracker: Bottle lost but didn't intersect enough. Resetting.");
            }
            reset();
          }
        }
        break;
        
      case DepositState.deposited:
        reset();
        break;
    }
  }

  bool _isIntersecting(DetectedBottle bottle) {
    // Check intersection between bottle.rect and slot bounding box
    final bx1 = bottle.rect[0];
    final by1 = bottle.rect[1];
    final bx2 = bottle.rect[2];
    final by2 = bottle.rect[3];

    final sx1 = slotLeft;
    final sy1 = slotTop;
    final sx2 = slotLeft + slotWidth;
    final sy2 = slotTop + slotHeight;

    // AABB intersection
    return !(bx2 < sx1 || bx1 > sx2 || by2 < sy1 || by1 > sy2);
  }
}
