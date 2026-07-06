import 'package:flutter_test/flutter_test.dart';
import 'package:eco_recycle/screens/scan/slot_motion_detection_impl.dart';

void main() {
  group('ArrowOcclusionDetector', () {
    test('counts a brief dip-and-recover cycle as one insertion', () {
      final detector = ArrowOcclusionDetector();

      for (var i = 0; i < 5; i++) {
        detector.push(0.20);
      }

      expect(detector.push(0.10), isFalse);
      expect(detector.push(0.10), isFalse);
      expect(detector.push(0.30), isTrue);
    });

    test('ignores a lingering occlusion that lasts too long', () {
      final detector = ArrowOcclusionDetector();

      for (var i = 0; i < 5; i++) {
        detector.push(0.20);
      }

      for (var i = 0; i < 13; i++) {
        detector.push(0.10);
      }

      expect(detector.push(0.30), isFalse);
    });
  });
}
