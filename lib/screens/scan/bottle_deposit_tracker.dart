import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../services/bottle_counting_service.dart';

enum DepositState {
  idle,
  detected,    // Bottle detected and initially tracked
  approaching, // Bottle moving downwards towards bin
  entering,    // Bottle intersecting bin opening
  deposited    // Bottle successfully deposited
}

class BottleDepositTracker {
  DepositState state = DepositState.idle;
  
  // The bounding box of the slot, normalized 0.0 to 1.0
  double slotLeft = 0.0;
  double slotTop = 0.0;
  double slotWidth = 0.0;
  double slotHeight = 0.0;
  
  double _initialY = 0.0;
  double _deepestY = 0.0; // Y increases downwards (0 top, 1 bottom)
  int _missingFrames = 0;
  bool _didIntersect = false;
  
  final VoidCallback onDeposited;
  
  BottleDepositTracker({required this.onDeposited});

  void reset() {
    state = DepositState.idle;
    _initialY = 0.0;
    _deepestY = 0.0;
    _missingFrames = 0;
    _didIntersect = false;
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
          // To start a sequence, the bottle must be held relatively high
          // and not already intersecting the slot target.
          if (!_isIntersecting(bestBottle) && bestBottle.centerY < slotTop + (slotHeight * 0.75)) {
            state = DepositState.detected;
            _initialY = bestBottle.centerY;
            _deepestY = bestBottle.centerY;
            _missingFrames = 0;
            _didIntersect = false;
            debugPrint("DEBUG LOG: Bottle detected");
            debugPrint("DEBUG LOG: Bottle tracked");
          }
        }
        break;

      case DepositState.detected:
        if (bestBottle != null) {
          _deepestY = max(_deepestY, bestBottle.centerY);
          _missingFrames = 0;
          
          // Require at least 5% downward movement from the *initial* Y coordinate
          if (_deepestY > _initialY + 0.05) {
            state = DepositState.approaching;
            debugPrint("DEBUG LOG: Bottle approaching bin");
          }
          
          // If user pulls the bottle back up significantly, reset tracking
          if (bestBottle.centerY < _deepestY - 0.15) {
            reset();
          }
        } else {
          _missingFrames++;
          if (_missingFrames > 10) reset();
        }
        break;

      case DepositState.approaching:
        if (bestBottle != null) {
          _deepestY = max(_deepestY, bestBottle.centerY);
          _missingFrames = 0;
          
          if (_isIntersecting(bestBottle)) {
            _didIntersect = true;
          }
          
          // Once it intersects the top of the slot, it's entering
          if (_didIntersect && bestBottle.centerY >= slotTop) {
            state = DepositState.entering;
            debugPrint("DEBUG LOG: Bottle entering bin");
          }
          
          if (bestBottle.centerY < _deepestY - 0.15) {
             reset();
          }
        } else {
          // If it disappears while approaching, maybe dropped fast
          if (_didIntersect) {
             state = DepositState.entering;
             debugPrint("DEBUG LOG: Bottle entering bin");
             _missingFrames = 1;
          } else {
             _missingFrames++;
             if (_missingFrames > 8) reset();
          }
        }
        break;

      case DepositState.entering:
        if (bestBottle != null) {
          _deepestY = max(_deepestY, bestBottle.centerY);
          _missingFrames = 0;
          
          if (_isIntersecting(bestBottle)) {
            // Unused intersecting frames tracker removed
          }
          
          if (bestBottle.centerY < _deepestY - 0.15) {
             reset();
          }
        } else {
          _missingFrames++;
          // Wait a few frames to confirm the bottle has disappeared into the bin
          if (_missingFrames > 3) {
            state = DepositState.deposited;
            debugPrint("DEBUG LOG: Bottle deposited");
            onDeposited();
            // onDeposited triggers _onBottleDetected in InsertionDetectorScreen,
            // which increments the session count and awards points.
            debugPrint("DEBUG LOG: Points awarded");
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
    final bx1 = bottle.rect[0];
    final by1 = bottle.rect[1];
    final bx2 = bottle.rect[2];
    final by2 = bottle.rect[3];

    final sx1 = slotLeft;
    final sy1 = slotTop;
    final sx2 = slotLeft + slotWidth;
    final sy2 = slotTop + slotHeight;

    return !(bx2 < sx1 || bx1 > sx2 || by2 < sy1 || by1 > sy2);
  }
}
