import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';
import 'scan_bin_screen.dart';
import 'scan_bottle_screen.dart';
import 'camera_confirm_screen.dart';
import 'scan_success_screen.dart';

/// Orchestrates: validate → scan bin → scan bottle → camera confirm → success.
class ScanFlowScreen extends StatefulWidget {
  const ScanFlowScreen({super.key});

  @override
  State<ScanFlowScreen> createState() => _ScanFlowScreenState();
}

class _ScanFlowScreenState extends State<ScanFlowScreen> {
  String? _binId;
  String? _barcode;
  String? _validationError;
  bool _validating = true;

  @override
  void initState() {
    super.initState();
    _validateAndStart();
  }

  Future<void> _validateAndStart() async {
    final userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      if (mounted) context.go('/login');
      return;
    }
    final validation = ScanValidationService(context.read<FirestoreService>());
    final error = await validation.validateBeforeScan(userId);
    if (!mounted) return;
    setState(() {
      _validationError = error;
      _validating = false;
    });
  }

  void _onBinScanned(String binId) {
    setState(() => _binId = binId);
  }

  void _onBottleScanned(String barcode) {
    setState(() => _barcode = barcode);
  }

  void _onSuccess() {
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
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
            ],
          ),
        ),
      );
    }

    if (_validationError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan Bottle')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
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
      );
    }

    // Step 1: Scan bin QR
    if (_binId == null) {
      return ScanBinScreen(
        onScanned: _onBinScanned,
        onBack: () => context.pop(),
      );
    }

    // Step 2: Scan bottle barcode
    if (_barcode == null) {
      return ScanBottleScreen(
        binId: _binId!,
        onScanned: _onBottleScanned,
        onBack: () => setState(() => _binId = null),
      );
    }

    // Step 3: Camera confirm (10s countdown + arrow detection)
    return CameraConfirmScreen(
      binId: _binId!,
      barcode: _barcode!,
      onSuccess: () => Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ScanSuccessScreen(onDone: _onSuccess),
        ),
      ),
      onBack: () => setState(() => _barcode = null),
    );
  }
}
