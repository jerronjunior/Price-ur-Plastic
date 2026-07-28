import 'package:flutter_test/flutter_test.dart';
import 'package:eco_recycle/screens/scan/slot_motion_detection_impl.dart';

void main() {
  group('ArrowOcclusionDetector', () {
    test('counts a brief localized dip as one insertion', () {
      final detector = ArrowOcclusionDetector();

      for (var i = 0; i < 5; i++) {
        detector.push(0.20, 0.50, 0.0, 0.0);
      }

      // Zone motion far exceeds corner motion — a real, localized insertion.
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isTrue);
    });

    test('re-arms after the arrow recovers so a second insertion also counts', () {
      final detector = ArrowOcclusionDetector();

      for (var i = 0; i < 5; i++) {
        detector.push(0.20, 0.50, 0.0, 0.0);
      }

      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isTrue);

      // Arrow visible again — re-arms for the next insertion.
      expect(detector.push(0.20, 0.50, 0.0, 0.0), isFalse);

      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isFalse);
      expect(detector.push(0.10, 0.50, 0.8, 0.1), isTrue);
    });

    test('ignores a non-localized dip (shake or full-camera-cover cheat)', () {
      final detector = ArrowOcclusionDetector();

      for (var i = 0; i < 5; i++) {
        detector.push(0.20, 0.50, 0.0, 0.0);
      }

      // Corner motion is as high as zone motion — the whole frame moved,
      // not just the slot, so this must never count.
      expect(detector.push(0.10, 0.50, 0.1, 0.5), isFalse);
      expect(detector.push(0.10, 0.50, 0.1, 0.5), isFalse);
      expect(detector.push(0.10, 0.50, 0.1, 0.5), isFalse);
    });
  });
}
