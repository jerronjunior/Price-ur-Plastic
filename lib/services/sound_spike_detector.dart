// lib/services/sound_spike_detector.dart
// ─────────────────────────────────────────────────────────────────────────────
// Detects a short, loud acoustic transient — the thud/clink of a bottle
// hitting the inside of a bin — independent of camera motion.
//
// Design: generic AMPLITUDE SPIKE detection, not a trained sound classifier.
// This is intentional — it works regardless of bin material (metal clang,
// plastic thud, soft swish) because it only asks "did the sound suddenly
// get much louder than the recent ambient level", not "does this match a
// specific waveform". That makes it robust across different bins without
// needing per-bin-type calibration.
//
// This is meant to be fused with SlotMotionDetectionImpl: a count should
// only be confirmed when BOTH a camera motion event AND a sound spike
// happen within a short time window of each other. Sound alone is too
// noisy (traffic, talking, music) to trust by itself — but combined with
// motion, it's a powerful filter that lets the motion threshold be more
// sensitive without increasing false positives.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';

class SoundSpikeEvent {
  const SoundSpikeEvent({required this.timestamp, required this.decibels, required this.aboveBaseline});
  final DateTime timestamp;
  final double decibels;
  final double aboveBaseline; // how many dB above the adaptive ambient floor
}

class SoundSpikeDetector {
  SoundSpikeDetector({this.onSpike});

  /// Called every time a qualifying spike is detected (already debounced).
  final void Function(SoundSpikeEvent event)? onSpike;

  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _sub;

  // Adaptive ambient noise floor — tracks the room's background noise level
  // so a quiet room and a noisy street both work without manual calibration.
  double? _baselineDb;
  static const double _baselineSmoothing = 0.05; // slow adaptation

  // How far above baseline counts as a "spike" — a bottle thud is typically
  // a sudden 12-20dB jump above ambient room noise.
  // Lowered to 5.0dB to detect small/quiet sounds (safe due to dual verification).
  static const double _spikeDeltaDb = 5.0;

  // Debounce so one physical thud doesn't fire multiple spike events as
  // the sound decays.
  static const Duration _debounce = Duration(milliseconds: 300);
  DateTime? _lastSpikeAt;

  bool _disposed = false;
  bool get isActive => _sub != null;

  /// Starts listening. Requests microphone permission if not already
  /// granted. Fails silently (motion-only fallback) if permission is
  /// denied or the platform doesn't support it — this feature must never
  /// block the core scanning flow.
  Future<void> start() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        debugPrint('[SoundSpike] Microphone permission denied — '
            'falling back to motion-only detection.');
        return;
      }

      _noiseMeter = NoiseMeter();
      _sub = _noiseMeter!.noise.listen(_onReading, onError: (e) {
        debugPrint('[SoundSpike] Stream error: $e — motion-only fallback.');
      });
      debugPrint('[SoundSpike] Listening started.');
    } catch (e) {
      debugPrint('[SoundSpike] start() failed: $e — motion-only fallback.');
    }
  }

  void _onReading(NoiseReading reading) {
    if (_disposed) return;
    final db = reading.meanDecibel;
    if (db.isNaN || db.isInfinite) return;

    if (_baselineDb == null) {
      _baselineDb = db; // first reading seeds the baseline
      return;
    }

    final delta = db - _baselineDb!;

    if (delta >= _spikeDeltaDb) {
      final now = DateTime.now();
      if (_lastSpikeAt == null || now.difference(_lastSpikeAt!) > _debounce) {
        _lastSpikeAt = now;
        debugPrint('[SoundSpike] Spike: ${db.toStringAsFixed(1)}dB '
            '(+${delta.toStringAsFixed(1)} above baseline)');
        onSpike?.call(SoundSpikeEvent(
          timestamp: now, decibels: db, aboveBaseline: delta,
        ));
      }
      // Don't let a loud moment drag the baseline up with it — only adapt
      // the baseline on non-spike (ambient) readings.
    } else {
      _baselineDb = _baselineDb! * (1 - _baselineSmoothing) + db * _baselineSmoothing;
    }
  }

  /// True if a spike happened within [window] of [around] (default: now).
  /// This is the fusion check SlotMotionDetectionImpl uses.
  bool hadRecentSpike({Duration window = const Duration(milliseconds: 800), DateTime? around}) {
    if (_lastSpikeAt == null) return false;
    final reference = around ?? DateTime.now();
    return reference.difference(_lastSpikeAt!).abs() <= window;
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _noiseMeter = null;
  }
}
