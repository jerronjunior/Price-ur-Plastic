// lib/widgets/insertion_guide_widget.dart
// Shows before InsertionDetectorScreen opens.
// Teaches user correct phone position and technique.

import 'package:flutter/material.dart';

class InsertionGuideWidget extends StatelessWidget {
  const InsertionGuideWidget({super.key, required this.onReady});

  final VoidCallback onReady;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),

          const Text('How to Insert Correctly',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 20),

          // Step illustrations
          const _Step(
            number: 1,
            icon: Icons.phone_android,
            color: Color(0xFF1565C0),
            title: 'Hold phone 15–20 cm above the bin slot',
            desc: 'Camera must see the full slot opening. Too close or far won\'t work.',
          ),
          const _Step(
            number: 2,
            icon: Icons.check_circle_outline,
            color: Color(0xFF2E7D32),
            title: 'Wait for green "Ready" indicator',
            desc: 'The app must lock onto the bin slot before you insert. Don\'t insert yet.',
          ),
          const _Step(
            number: 3,
            icon: Icons.arrow_downward,
            color: Color(0xFFF57F17),
            title: 'Drop bottle straight down through the slot',
            desc: 'Use ONE hand. Drop smoothly. Don\'t wave or push sideways.',
          ),
          const _Step(
            number: 4,
            icon: Icons.do_not_touch,
            color: Color(0xFFC62828),
            title: 'Do NOT pull your hand back out',
            desc: 'After releasing the bottle, move your hand to the SIDE. Pulling back up triggers a false count.',
          ),
          const _Step(
            number: 5,
            icon: Icons.emoji_events,
            color: Color(0xFF2E7D32),
            title: 'Wait for "+N pts" to appear',
            desc: 'The flash and points badge confirm the insertion was counted.',
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onReady,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('I understand — open camera',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                )),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.icon,
    required this.color,
    required this.title,
    required this.desc,
  });

  final int      number;
  final IconData icon;
  final Color    color;
  final String   title;
  final String   desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text(desc,
                  style: TextStyle(
                    fontSize: 12, color: Colors.grey[600], height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Show the guide as a bottom sheet before opening InsertionDetectorScreen.
/// Usage:
///   await showInsertionGuide(context);
///   // then open InsertionDetectorScreen
Future<void> showInsertionGuide(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InsertionGuideWidget(
      onReady: () => Navigator.of(context).pop(),
    ),
  );
}
