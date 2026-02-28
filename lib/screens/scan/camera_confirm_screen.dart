import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';
import '../../models/recycled_bottle_model.dart';
import '../../services/firestore_service.dart';
import 'arrow_detection.dart';

/// Camera video mode: 10s countdown, arrow region, detect change to confirm bottle inserted.
class CameraConfirmScreen extends StatefulWidget {
  const CameraConfirmScreen({
    super.key,
    this.binId = '',
    required this.barcode,
    required this.onSuccess,
    required this.onBack,
  });

  final String binId;
  final String barcode;
  final VoidCallback onSuccess;
  final VoidCallback onBack;

  @override
  State<CameraConfirmScreen> createState() => _CameraConfirmScreenState();
}

class _CameraConfirmScreenState extends State<CameraConfirmScreen> {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  bool _initialized = false;
  String? _error;
  int _countdown = AppConstants.scanCountdownSeconds;
  Timer? _countdownTimer;
  bool _confirmed = false;
  bool _saving = false;

  /// Arrow region as fraction of preview (center rectangle).
  static const double _regionLeft = 0.35;
  static const double _regionTop = 0.35;
  static const double _regionWidth = 0.3;
  static const double _regionHeight = 0.25;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        setState(() => _error = 'No camera found');
        return;
      }
      final camera = _cameras!.first;
      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);
      _startCountdown();
    } catch (e) {
      setState(() => _error = 'Camera error: $e');
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _countdown--;
        if (_countdown <= 0) {
          _countdownTimer?.cancel();
          if (!_confirmed) _onTimeout();
        }
      });
    });
  }

  void _onTimeout() {
    if (_saving) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Time\'s up'),
        content: const Text(
          'Insert the bottle into the bin and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((_) => widget.onBack());
  }

  void _onArrowDisappeared() {
    if (_confirmed || _saving) return;
    _countdownTimer?.cancel();
    setState(() => _confirmed = true);
    _saveAndComplete();
  }

  Future<void> _saveAndComplete() async {
    setState(() => _saving = true);
    final userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      setState(() => _saving = false);
      return;
    }
    final firestore = context.read<FirestoreService>();
    final bottle = RecycledBottleModel(
      barcode: widget.barcode,
      userId: userId,
      binId: widget.binId,
      timestamp: DateTime.now(),
    );
    try {
      await firestore.saveRecycledBottle(bottle);
      if (!mounted) return;
      widget.onSuccess();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Confirm insertion'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                ElevatedButton(onPressed: widget.onBack, child: const Text('Back')),
              ],
            ),
          ),
        ),
      );
    }

    if (!_initialized || _controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Confirm insertion'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Insert bottle'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),
              Positioned(
                left: w * _regionLeft,
                top: h * _regionTop,
                width: w * _regionWidth,
                height: h * _regionHeight,
                child: ArrowRegionOverlay(
                  controller: _controller!,
                  onArrowDisappeared: _onArrowDisappeared,
                  countdown: _countdown,
                  disabled: _confirmed || _saving,
                ),
              ),
              Positioned(
                top: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _countdown > 0 ? '$_countdown' : '0',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (_saving)
                const Positioned(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text('Saving...', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
