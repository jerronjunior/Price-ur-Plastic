import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../providers/auth_provider.dart';
import '../../models/recycled_bottle_model.dart';
import '../../services/firestore_service.dart';
import 'arrow_detection.dart';

/// Camera confirm screen: 10s countdown, arrow region overlay, detect bottle insertion.
///
/// Camera fixes applied:
/// - Uses platform-correct ImageFormatGroup (yuv420 on Android, bgra8888 on iOS)
/// - Waits for controller to be fully settled before building preview
/// - Guards against double-dispose and stream conflicts
/// - Retries camera init once on failure
/// - Safe stopImageStream before dispose
class CameraConfirmScreen extends StatefulWidget {
  const CameraConfirmScreen({
    super.key,
    this.binId = '',
    required this.barcode,
    required this.onSuccess,
    this.onTimeout,
    required this.onBack,
  });

  final String binId;
  final String barcode;
  final VoidCallback onSuccess;
  final VoidCallback? onTimeout;
  final VoidCallback onBack;

  @override
  State<CameraConfirmScreen> createState() => _CameraConfirmScreenState();
}

class _CameraConfirmScreenState extends State<CameraConfirmScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _initialized = false;
  String? _error;
  int _countdown = AppConstants.scanCountdownSeconds;
  Timer? _countdownTimer;
  bool _confirmed = false;
  bool _saving = false;
  bool _disposed = false;
  bool _overlayVisible = false;

  /// Fraction of preview used for arrow detection region
  static const double _regionLeft = 0.25;
  static const double _regionTop = 0.30;
  static const double _regionWidth = 0.50;
  static const double _regionHeight = 0.35;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        // Stop stream before disposing to prevent platform errors
        if (controller.value.isInitialized &&
            controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  Future<void> _initCamera({bool retry = false}) async {
    if (_disposed) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!_disposed && mounted) {
          setState(() => _error = 'No camera found on this device.');
        }
        return;
      }

      // Prefer back camera
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Use platform-correct image format
      final imageFormat = Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420;

      final controller = CameraController(
        camera,
        ResolutionPreset.medium, // medium = good balance of performance/quality
        enableAudio: false,
        imageFormatGroup: imageFormat,
      );

      await controller.initialize();

      // Let the camera sensor settle for a moment before streaming
      await Future.delayed(const Duration(milliseconds: 300));

      if (_disposed || !mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _initialized = true;
        _error = null;
      });

      // Small extra delay before showing overlay to avoid grabbing a dark frame
      await Future.delayed(const Duration(milliseconds: 500));
      if (!_disposed && mounted) {
        setState(() => _overlayVisible = true);
        _startCountdown();
      }
    } catch (e) {
      if (_disposed || !mounted) return;

      // Retry once automatically
      if (!retry) {
        await Future.delayed(const Duration(milliseconds: 500));
        return _initCamera(retry: true);
      }

      setState(() => _error = 'Could not access camera: $e\n\nPlease check camera permissions and try again.');
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || !mounted) return;
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
    if (_saving || _disposed) return;
    // If caller provided onTimeout, use it (shows Try Again screen)
    if (widget.onTimeout != null) {
      widget.onTimeout!();
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Time's up"),
        content: const Text(
          'No bottle was detected in time.\nPlease insert the bottle into the bin and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((_) {
      if (mounted) widget.onBack();
    });
  }

  void _onArrowDisappeared() {
    if (_confirmed || _saving || _disposed) return;
    _countdownTimer?.cancel();
    setState(() => _confirmed = true);
    _saveAndComplete();
  }

  Future<void> _saveAndComplete() async {
    if (_disposed) return;
    setState(() => _saving = true);

    final userId = context.read<AuthProvider>().userId;
    if (userId == null) {
      if (mounted) setState(() => _saving = false);
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
      if (!_disposed && mounted) widget.onSuccess();
    } catch (e) {
      if (!_disposed && mounted) {
        setState(() {
          _saving = false;
          _confirmed = false;
          _error = 'Failed to save: $e';
        });
      }
    }
  }

  // ──────────────────────────────────────────────── UI

  @override
  Widget build(BuildContext context) {
    // Error state
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Confirm Insertion'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack,
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _initialized = false;
                    });
                    _initCamera();
                  },
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: widget.onBack,
                  child: const Text('Go Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Loading state
    if (!_initialized || _controller == null || !_controller!.value.isInitialized) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Confirm Insertion'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack,
          ),
        ),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Starting camera...'),
            ],
          ),
        ),
      );
    }

    // Main camera view
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Insert Bottle',
          style: TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: widget.onBack,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          return Stack(
            alignment: Alignment.center,
            children: [
              // Full-screen camera preview
              Positioned.fill(
                child: CameraPreview(_controller!),
              ),

              // Arrow region overlay (detection box)
              if (_overlayVisible)
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

              // Countdown timer badge
              Positioned(
                top: 16,
                child: _CountdownBadge(
                  countdown: _countdown,
                  confirmed: _confirmed,
                ),
              ),

              // Instruction text at bottom
              if (!_confirmed && !_saving)
                Positioned(
                  bottom: 24,
                  left: 24,
                  right: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Point camera at the bin\'s arrow mark, then insert the bottle',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),

              // Saving indicator
              if (_saving)
                Container(
                  color: Colors.black54,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          'Saving...',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),

              // Confirmed flash overlay
              if (_confirmed && !_saving)
                Container(
                  color: Colors.green.withOpacity(0.3),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, color: Colors.white, size: 80),
                        SizedBox(height: 16),
                        Text(
                          'Bottle detected!',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Animated countdown badge shown at the top of the screen.
class _CountdownBadge extends StatelessWidget {
  const _CountdownBadge({required this.countdown, required this.confirmed});

  final int countdown;
  final bool confirmed;

  @override
  Widget build(BuildContext context) {
    final isUrgent = countdown <= 3 && !confirmed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: confirmed
            ? Colors.green.withOpacity(0.85)
            : isUrgent
                ? Colors.red.withOpacity(0.85)
                : Colors.black54,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        confirmed ? '✓' : '$countdown',
        style: TextStyle(
          color: Colors.white,
          fontSize: confirmed ? 28 : 36,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}