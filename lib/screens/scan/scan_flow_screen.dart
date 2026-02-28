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

    // Step 1: Scan bottle barcode
    if (_barcode == null) {
      return ScanBottleScreen(
        onScanned: _onBottleScanned,
        onBack: () => context.pop(),
      );
    }

    // Step 2: Camera confirm (10s countdown + arrow detection)
    return CameraConfirmScreen(
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
  }}