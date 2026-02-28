import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';

/// Scan bottle barcode with frame overlay; validate not already recycled.
class ScanBottleScreen extends StatefulWidget {
  const ScanBottleScreen({
    super.key,
    required this.onScanned,
    required this.onBack,
  });

  final void Function(String barcode) onScanned;
  final VoidCallback onBack;

  @override
  State<ScanBottleScreen> createState() => _ScanBottleScreenState();
}

class _ScanBottleScreenState extends State<ScanBottleScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _processing = false;
  String? _error;
  String? _scannedResult;

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
    final validation = ScanValidationService(firestore);
    final err = await validation.validateBarcode(code);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _processing = false;
      });
      return;
    }
    
    // Show result temporarily before proceeding
    setState(() => _scannedResult = code);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      widget.onScanned(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Blue Header
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.person, color: Colors.white),
                    onPressed: context.pop,
                  ),
                  const Text(
                    'PuP',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.notifications, color: Colors.white),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
          // Camera with frame overlay
          Expanded(
            child: Stack(
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                ),
                // Blue frame overlay
                Center(
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF1565C0),
                        width: 4,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                // Horizontal line through center
                Center(
                  child: Container(
                    width: 300,
                    height: 1,
                    color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                  ),
                ),
                // Help text below frame
                Positioned(
                  bottom: 60,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: [
                      Text(
                        'Align barcode within frame...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_scannedResult != null) ...[
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.shade700,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'Scan result: $_scannedResult',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.shade700,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _BottomNavItem(
              icon: Icons.home,
              label: 'Home',
              isActive: false,
              onTap: () => context.push('/home'),
            ),
            _BottomNavItem(
              icon: Icons.leaderboard,
              label: 'Leaderboard',
              isActive: false,
              onTap: () => context.push('/leaderboard'),
            ),
            _BottomNavItem(
              icon: Icons.camera_alt,
              label: 'Scan',
              isActive: true,
              onTap: () {},
            ),
            _BottomNavItem(
              icon: Icons.card_giftcard,
              label: 'Rewards',
              isActive: false,
              onTap: () => context.push('/rewards'),
            ),
            _BottomNavItem(
              icon: Icons.person,
              label: 'Profile',
              isActive: false,
              onTap: () => context.push('/profile'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const primaryBlue = Color(0xFF1565C0);
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isActive ? primaryBlue : Colors.grey.shade700,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: isActive ? primaryBlue : Colors.grey.shade700,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
