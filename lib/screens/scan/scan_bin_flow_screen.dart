import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../models/recycled_bottle_model.dart';
import 'insertion_detector_screen.dart';
import 'scan_bottle_screen.dart';
import 'scan_bin_screen.dart';

/// Orchestrates bin barcode scanning flow.
class ScanBinFlowScreen extends StatefulWidget {
  const ScanBinFlowScreen({super.key});

  @override
  State<ScanBinFlowScreen> createState() => _ScanBinFlowScreenState();
}

class _ScanBinFlowScreenState extends State<ScanBinFlowScreen> {
  bool _bottleDetecting = false;
  bool _cameraConfirming = false;
  bool _processing = false;
  bool _showSuccess = false;
  bool _showSummary = false;
  int _bottleCount = 0;
  int _totalPoints = 0;
  int _totalBottles = 0;
  String? _lastBinId;
  String? _lastBarcode;

  Future<void> _onBinScanned(String binId) async {
    setState(() {
      _lastBinId = binId;
      _bottleDetecting = true;
      _cameraConfirming = false;
      _showSuccess = false;
    });
  }

  void _onBottleDetected(String barcode) {
    if (_lastBinId == null) return;

    setState(() {
      _lastBarcode = barcode;
      _bottleDetecting = false;
      _cameraConfirming = true;
      _showSuccess = false;
    });
  }

  Future<void> _recordBottle(String binId) async {
    setState(() {
      _cameraConfirming = false;
      _processing = true;
      _showSummary = false;
    });

    try {
      final userId = context.read<AuthProvider>().userId;
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final firestore = context.read<FirestoreService>();

      final barcode = _lastBarcode;
      if (barcode == null || barcode.trim().isEmpty) {
        throw StateError('Bottle barcode missing. Please scan the bottle again.');
      }

      await firestore.saveRecycledBottle(
        RecycledBottleModel(
          barcode: barcode,
          userId: userId,
          binId: binId,
          timestamp: DateTime.now(),
        ),
      );

      // Log the bin scan
      await firestore.logBinScan(userId, binId);

      if (!mounted) return;
      setState(() {
        _bottleCount++;
        _showSuccess = true;
        _cameraConfirming = false;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _finishSession() async {
    setState(() {
      _processing = true;
    });

    try {
      final auth = context.read<AuthProvider>();
      final userId = auth.userId;
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final firestore = context.read<FirestoreService>();
      final latestUser = await firestore.getUser(userId);

      if (!mounted) return;
      setState(() {
        _totalPoints = latestUser?.totalPoints ?? auth.user?.totalPoints ?? 0;
        _totalBottles = latestUser?.totalBottles ?? auth.user?.totalBottles ?? 0;
        _showSummary = true;
        _showSuccess = false;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading points summary: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bottleDetecting && _lastBinId != null) {
      return ScanBottleScreen(
        onScanned: _onBottleDetected,
        onBack: () {
          if (!mounted) return;
          setState(() {
            _bottleDetecting = false;
          });
        },
      );
    }

    if (_cameraConfirming && _lastBinId != null) {
      return InsertionDetectorScreen(
        onDetected: () => _recordBottle(_lastBinId!),
        onTimeout: () {
          if (!mounted) return;
          setState(() {
            _cameraConfirming = false;
            _bottleDetecting = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No bottle insertion detected. Please scan bottle again.'),
            ),
          );
        },
        onBack: () {
          if (!mounted) return;
          setState(() {
            _cameraConfirming = false;
            _bottleDetecting = true;
          });
        },
        timeoutSeconds: 20,
      );
    }

    if (_showSummary) {
      final sessionPoints = _bottleCount * AppConstants.pointsPerBottle;
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.emoji_events,
                  size: 88,
                  color: Color(0xFFFFA000),
                ),
                const SizedBox(height: 24),
                Text(
                  'Recycling Complete',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'You added $_bottleCount bottle${_bottleCount == 1 ? '' : 's'} in this session.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 28),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F8E9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFC8E6C9)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Session Points: +$sessionPoints',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF2E7D32),
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Total Points: $_totalPoints',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Total Bottles: $_totalBottles',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.home),
                    label: const Text('Go Home'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: () => context.go('/'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_showSuccess) {
      final pts = _bottleCount;
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 80,
                  color: Color(0xFF4CAF50),
                ),
                const SizedBox(height: 24),
                Text(
                  'Bottle${pts > 1 ? 's' : ''} recorded successfully!',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '+$pts point${pts > 1 ? 's' : ''} and +$pts bottle${pts > 1 ? 's' : ''}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: const Color(0xFF4CAF50), fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 48),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _processing
                            ? null
                            : () => setState(() {
                                  _bottleDetecting = true;
                                  _cameraConfirming = false;
                                  _showSuccess = false;
                                }),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.check),
                        label: const Text('Finished'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: const Color(0xFF4CAF50),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _processing ? null : _finishSession,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_processing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scanning Bin')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Processing bin scan...',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      );
    }

    return ScanBinScreen(
      onScanned: _onBinScanned,
      onBack: () => context.go('/'),
    );
  }
}