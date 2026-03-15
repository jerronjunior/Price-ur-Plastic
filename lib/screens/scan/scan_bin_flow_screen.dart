import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import 'camera_confirm_screen.dart';
import 'scan_bin_screen.dart';

/// Orchestrates bin barcode scanning flow.
class ScanBinFlowScreen extends StatefulWidget {
  const ScanBinFlowScreen({super.key});

  @override
  State<ScanBinFlowScreen> createState() => _ScanBinFlowScreenState();
}

class _ScanBinFlowScreenState extends State<ScanBinFlowScreen> {
  bool _cameraConfirming = false;
  bool _processing = false;
  bool _showSuccess = false;
  int _bottleCount = 0;
  String? _lastBinId;

  Future<void> _onBinScanned(String binId) async {
    setState(() {
      _lastBinId = binId;
      _cameraConfirming = true;
      _showSuccess = false;
    });
  }

  Future<void> _recordBottle(String binId) async {
    setState(() {
      _cameraConfirming = false;
      _processing = true;
    });

    try {
      final userId = context.read<AuthProvider>().userId;
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final firestore = context.read<FirestoreService>();

      // Keep points and bottle count in sync: +1 point and +1 bottle.
      await firestore.incrementUserPointsAndBottles(userId);

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

  @override
  Widget build(BuildContext context) {
    if (_cameraConfirming && _lastBinId != null) {
      return CameraConfirmScreen(
        binId: _lastBinId!,
        onSuccess: () => _recordBottle(_lastBinId!),
        onTimeout: () {
          if (!mounted) return;
          setState(() {
            _cameraConfirming = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No bottle detected within 15 seconds. Please scan the bin again.'),
            ),
          );
        },
        onBack: () {
          if (!mounted) return;
          setState(() {
            _cameraConfirming = false;
          });
        },
        countdownSeconds: 15,
        autoSaveBottleRecord: false,
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
                                  _cameraConfirming = true;
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
                        onPressed: () => context.go('/'),
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