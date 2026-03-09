import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import 'scan_bin_screen.dart';

/// Orchestrates bin barcode scanning flow.
class ScanBinFlowScreen extends StatefulWidget {
  const ScanBinFlowScreen({super.key});

  @override
  State<ScanBinFlowScreen> createState() => _ScanBinFlowScreenState();
}

class _ScanBinFlowScreenState extends State<ScanBinFlowScreen> {
  bool _processing = false;
  String? _successMessage;

  Future<void> _onBinScanned(String binId) async {
    setState(() {
      _processing = true;
    });

    try {
      final userId = context.read<AuthProvider>().userId;
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final firestore = context.read<FirestoreService>();
      
      // Add points for bin scan (10 points)
      await firestore.incrementUserPoints(userId, 10);
      
      // Log the bin scan
      await firestore.logBinScan(userId, binId);

      if (!mounted) return;
      setState(() {
        _successMessage = 'Bin scanned successfully!\n+10 points earned';
        _processing = false;
      });

      // Show success and return after 2 seconds
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        context.pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_successMessage != null) {
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
                  _successMessage!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
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
      onBack: () => context.pop(),
    );
  }
}
