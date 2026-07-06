import 'package:eco_recycle/screens/scan/insertion_detector_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OcclusionEventDetector', () {
    test('counts once when a previously locked slot stays hidden long enough', () {
      final detector = OcclusionEventDetector(
        minOcclusion: const Duration(milliseconds: 250),
        maxOcclusion: const Duration(seconds: 2),
        cooldown: const Duration(seconds: 2),
      );

      final start = DateTime(2024, 1, 1, 12, 0, 0);

      expect(detector.update(slotVisible: true, now: start), isFalse);
      expect(detector.update(slotVisible: false, now: start.add(const Duration(milliseconds: 100))), isFalse);
      expect(detector.update(slotVisible: false, now: start.add(const Duration(milliseconds: 400))), isTrue);
      expect(detector.update(slotVisible: false, now: start.add(const Duration(milliseconds: 500))), isFalse);
    });

    test('ignores very short flickers below the minimum occlusion', () {
      final detector = OcclusionEventDetector(
        minOcclusion: const Duration(milliseconds: 250),
        maxOcclusion: const Duration(seconds: 2),
        cooldown: const Duration(seconds: 2),
      );

      final start = DateTime(2024, 1, 1, 12, 0, 0);

      expect(detector.update(slotVisible: true, now: start), isFalse);
      expect(detector.update(slotVisible: false, now: start.add(const Duration(milliseconds: 100))), isFalse);
      expect(detector.update(slotVisible: true, now: start.add(const Duration(milliseconds: 150))), isFalse);
    });
  });
}
