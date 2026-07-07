import 'dart:async';

/// An optional detector that listens for sudden spikes in audio (like a bottle dropping).
/// It is non-blocking and handles its own permissions.
class SoundSpikeDetector {
  bool _isListening = false;
  final List<DateTime> _spikes = [];

  /// Requests permission and starts listening for audio spikes.
  /// Does not block the main camera flow if denied.
  Future<void> start() async {
    // TODO: Implement actual audio listening logic (e.g., using record package)
    _isListening = true;
  }

  /// Checks if a sound spike was detected within the given [window].
  bool hadRecentSpike({required Duration window}) {
    if (!_isListening || _spikes.isEmpty) return false;
    
    final now = DateTime.now();
    return _spikes.any((spikeTime) => now.difference(spikeTime) <= window);
  }

  /// Stops listening and cleans up resources.
  void dispose() {
    _isListening = false;
    _spikes.clear();
  }
}
