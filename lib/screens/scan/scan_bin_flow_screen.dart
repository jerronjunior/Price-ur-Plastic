import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../models/recycled_bottle_model.dart';
import 'insertion_detector_screen.dart';
import 'scan_bottle_screen.dart';
import 'scan_bin_screen.dart';
import 'scan_success_screen.dart';

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

  int _bottleCount = 0;   // bottles recorded this session
  int _totalPoints = 0;   // user's total points (loaded on finish)
  int _totalBottles = 0;  // user's total bottles (loaded on finish)

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
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _finishSession() async {
    setState(() => _processing = true);

    try {
      final auth = context.read<AuthProvider>();
      final userId = auth.userId;
      if (userId == null) {
        if (mounted) context.go('/login');
        return;
      }

      final latestUser =
          await context.read<FirestoreService>().getUser(userId);

      if (!mounted) return;
      setState(() {
        _totalPoints = latestUser?.totalPoints ?? auth.user?.totalPoints ?? 0;
        _totalBottles = latestUser?.totalBottles ?? auth.user?.totalBottles ?? 0;
        _showSuccess = false;
        _showSummary = true;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading summary: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── Bottle barcode scan ─────────────────────────────────────────────────
    if (_bottleDetecting && _lastBinId != null) {
      return ScanBottleScreen(
        onScanned: _onBottleDetected,
        onBack: () {
          if (!mounted) return;
          setState(() => _bottleDetecting = false);
        },
      );
    }

    // ── Insertion detection ─────────────────────────────────────────────────
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
              content: Text('No bottle detected. Please scan bottle again.'),
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

    // ── Success screen (per bottle) ─────────────────────────────────────────
    if (_showSuccess) {
      return ScanSuccessScreen(
        onAddBottle: () => setState(() {
          _showSuccess = false;
          _bottleDetecting = true;
        }),
        onFinish: _finishSession,
      );
    }

    // ── Session summary ─────────────────────────────────────────────────────
    if (_showSummary) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.emoji_events_rounded,
                  size: 88,
                  color: Color(0xFFFFA000),
                ),
                const SizedBox(height: 24),
                Text(
                  'Session Complete!',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You recycled $_bottleCount bottle${_bottleCount == 1 ? '' : 's'} this session.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: Colors.grey.shade600),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: 24, horizontal: 20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F8E9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFC8E6C9)),
                  ),
                  child: Column(
                    children: [
                      _SummaryRow(
                        label: 'Points this session',
                        value: '+$_bottleCount',
                        valueColor: const Color(0xFF2E7D32),
                      ),
                      const Divider(height: 28),
                      _SummaryRow(
                        label: 'Total points',
                        value: '$_totalPoints',
                      ),
                      const SizedBox(height: 8),
                      _SummaryRow(
                        label: 'Total bottles',
                        value: '$_totalBottles',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 36),
                ElevatedButton.icon(
                  icon: const Icon(Icons.home),
                  label: const Text('Go Home'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => context.go('/'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ── Processing spinner ──────────────────────────────────────────────────
    if (_processing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scanning Bin')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // ── Bin QR scan ─────────────────────────────────────────────────────────
    return ScanBinScreen(
      onScanned: _onBinScanned,
      onBack: () => context.go('/'),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.grey.shade700)),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
        ),
      ],
    );
  }
}
