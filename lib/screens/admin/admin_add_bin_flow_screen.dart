import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'add_bin_screen.dart';
import '../../screens/scan/scan_bin_screen.dart';

/// AdminAddBinFlowScreen
///
/// Orchestrates the admin bin addition flow:
/// 1. Scan bin QR code (like users do)
/// 2. Verify bin details and add location information
class AdminAddBinFlowScreen extends StatefulWidget {
  const AdminAddBinFlowScreen({super.key});

  @override
  State<AdminAddBinFlowScreen> createState() => _AdminAddBinFlowScreenState();
}

class _AdminAddBinFlowScreenState extends State<AdminAddBinFlowScreen> {
  String? _scannedBinType;

  void _onBinScanned(String binType) {
    setState(() => _scannedBinType = binType);
  }

  void _onBack() {
    if (_scannedBinType != null) {
      setState(() => _scannedBinType = null);
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Step 1: Scan bin QR code
    if (_scannedBinType == null) {
      return ScanBinScreen(
        onScanned: _onBinScanned,
        onBack: () => context.pop(),
      );
    }

    // Step 2: Add location details
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Bin Location'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _onBack,
        ),
      ),
      body: AddBinScreen(
        scannedBinType: _scannedBinType,
      ),
    );
  }
}
