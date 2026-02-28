import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/theme.dart';
import '../../services/firestore_service.dart';

/// Scan bin QR code to get bin ID.
class ScanBinScreen extends StatefulWidget {
  const ScanBinScreen({
    super.key,
    required this.onScanned,
    required this.onBack,
  });

  final void Function(String binId) onScanned;
  final VoidCallback onBack;

  @override
  State<ScanBinScreen> createState() => _ScanBinScreenState();
}

class _ScanBinScreenState extends State<ScanBinScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _processing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final code = barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    final firestore = context.read<FirestoreService>();
    final bin = await firestore.getBin(code);
    if (!mounted) return;
    if (bin != null) {
      widget.onScanned(bin.binId);
    } else {
      setState(() {
        _error = 'Unknown bin. Please scan a valid recycling bin QR code.';
        _processing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Bin QR'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          if (_error != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Positioned(
              left: 24,
              right: 24,
              bottom: 48,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Point your camera at the recycling bin QR code',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
