import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';
import 'scan_bottle_screen.dart';
import 'camera_confirm_screen.dart';
import 'scan_success_screen.dart';
import '../../widgets/bottom_nav_bar.dart';

/// Orchestrates: validate → scan bottle → camera confirm → success.
class ScanFlowScreen extends StatefulWidget {
  const ScanFlowScreen({super.key});

  @override
  State<ScanFlowScreen> createState() => _ScanFlowScreenState();
}

class _ScanFlowScreenState extends State<ScanFlowScreen> {
  String? _barcode;
  String? _validationError;
  bool _validating = true;

  @override
  void initState() {
    super.initState();
    _validateAndStart();
  }

  Future<void> _validateAndStart() async {
    // Safety: if validation takes >8s, give up and let the user through.
    // This prevents the screen freezing forever on Firestore timeout.
    try {
      final userId = context.read<AuthProvider>().userId;

      // If not logged in, redirect immediately
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final validation = ScanValidationService(context.read<FirestoreService>());

      // Run with a timeout — if Firestore hangs, don't freeze the user
      final error = await validation
          .validateBeforeScan(userId)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => null, // null = no error = let them proceed
          );

      if (!mounted) return;
      setState(() {
        _validationError = error;
        _validating = false;
      });
    } catch (e) {
      // ANY error (network, Firestore, null dereference) → just proceed to scan.
      // Validation is a soft guard, not a hard blocker.
      debugPrint('ScanFlowScreen: validation error (ignored): $e');
      if (!mounted) return;
      setState(() {
        _validationError = null; // let them through
        _validating = false;
      });
    }
  }

  void _onBottleScanned(String barcode) {
    setState(() => _barcode = barcode);
  }

  void _onSuccess() {
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    // ── Validating (with timeout safety)
    if (_validating) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Checking cooldown & daily limit...',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              // Show retry hint after 3 seconds so user knows what to do
              FutureBuilder(
                future: Future.delayed(const Duration(seconds: 3)),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const SizedBox.shrink();
                  }
                  return TextButton(
                    onPressed: () {
                      setState(() => _validating = true);
                      _validateAndStart();
                    },
                    child: const Text('Taking too long? Tap to retry'),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    // ── Validation returned an error (cooldown / daily limit hit)
    if (_validationError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan Bottle')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 64,
                  color: AppTheme.error,
                ),
                const SizedBox(height: 24),
                Text(
                  _validationError!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: const AppBottomNavBar(currentRoute: '/scan'),
      );
    }

    // ── Step 1: Scan bottle barcode
    if (_barcode == null) {
      return ScanBottleScreen(
        onScanned: _onBottleScanned,
        onBack: () => context.pop(),
      );
    }

    // ── Step 2: Camera confirm (10s countdown + slot-motion detection)
    return CameraConfirmScreen(
      barcode: _barcode!,
      binId: '',
      onSuccess: () => Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ScanSuccessScreen(onDone: _onSuccess),
        ),
      ),
      onBack: () => setState(() => _barcode = null),
    );
  }
}