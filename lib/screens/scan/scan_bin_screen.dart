import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/theme.dart';
import '../../models/bin_model.dart';
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
  static bool get _isDesktopPlatform =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static CameraFacing get _defaultFacing =>
      CameraFacing.back;

  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
    facing: _defaultFacing,
    torchEnabled: false,
  );

  bool _cameraStarting = false;
  bool _switchingCamera = false;
  bool _desktopCameraReady = false;
  bool _desktopAnalyzing = false;
  bool _processing = false;
  String? _error;
  String? _cameraError;
  String? _cameraInfo;

  CameraController? _desktopCameraController;
  List<CameraDescription> _desktopCameras = const [];
  int _desktopCameraIndex = 0;
  Timer? _desktopScanTimer;
  StreamSubscription<BarcodeCapture>? _desktopBarcodeSub;

  @override
  void initState() {
    super.initState();
    if (_isDesktopPlatform) {
      _setupDesktopScanner();
    } else {
      _startScannerWithFallback();
    }
  }

  Future<void> _setupDesktopScanner() async {
    _desktopBarcodeSub ??= _controller.barcodes.listen(_onDetect);
    await _initDesktopCamera();
  }

  String _buildCameraErrorMessage(Object error) {
    final details = error.toString();
    final lower = details.toLowerCase();

    if (lower.contains('permission') || lower.contains('notallowed')) {
      return 'Camera permission denied. Enable camera access in Windows Privacy Settings for desktop apps.';
    }
    if (lower.contains('notfound') || lower.contains('unavailable')) {
      return 'No usable camera was found. Check camera connection and close other apps that might be using it.';
    }
    return 'Camera is unavailable. $details';
  }

  Future<void> _startScannerWithFallback() async {
    if (_isDesktopPlatform) {
      await _initDesktopCamera();
      return;
    }

    if (_cameraStarting) {
      return;
    }

    _cameraStarting = true;
    if (mounted) {
      setState(() {
        _cameraInfo = 'Starting camera...';
        _cameraError = null;
      });
    }

    final fallbackFacing =
        _defaultFacing == CameraFacing.front ? CameraFacing.back : CameraFacing.front;

    try {
      await _controller.start(cameraFacingOverride: _defaultFacing);
      if (!mounted) return;
      setState(() {
        _cameraInfo = null;
        _cameraError = null;
      });
    } catch (primaryError) {
      debugPrint('Primary scanner start failed: $primaryError');
      try {
        await _controller.start(cameraFacingOverride: fallbackFacing);
        if (!mounted) return;
        setState(() {
          _cameraInfo = 'Primary camera unavailable. Switched to alternate camera.';
          _cameraError = null;
        });
      } catch (fallbackError) {
        if (!mounted) return;
        setState(() {
          _cameraInfo = null;
          _cameraError = _buildCameraErrorMessage(fallbackError);
        });
      }
    } finally {
      _cameraStarting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _retryCamera() async {
    if (_isDesktopPlatform) {
      await _initDesktopCamera();
      return;
    }

    try {
      await _controller.stop();
    } catch (_) {}
    await _startScannerWithFallback();
  }

  Future<void> _switchCameraManually() async {
    if (_isDesktopPlatform) {
      await _switchDesktopCamera();
      return;
    }

    if (_switchingCamera) return;

    _switchingCamera = true;
    if (mounted) {
      setState(() {
        _cameraInfo = 'Switching camera...';
        _cameraError = null;
      });
    }

    try {
      await _controller.switchCamera();
      if (!mounted) return;
      setState(() {
        _cameraInfo = 'Camera switched successfully.';
        _cameraError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraInfo = null;
        _cameraError = _buildCameraErrorMessage(e);
      });
    } finally {
      _switchingCamera = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _initDesktopCamera({int? forcedIndex}) async {
    if (_cameraStarting) return;
    _cameraStarting = true;

    if (mounted) {
      setState(() {
        _cameraInfo = 'Starting laptop camera...';
        _cameraError = null;
      });
    }

    try {
      _desktopCameras = await availableCameras();
      if (_desktopCameras.isEmpty) {
        throw CameraException('no_camera', 'No camera found on this device.');
      }

      if (forcedIndex != null) {
        _desktopCameraIndex = forcedIndex % _desktopCameras.length;
      } else {
        final back = _desktopCameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
        _desktopCameraIndex = back >= 0 ? back : 0;
      }

      final controller = CameraController(
        _desktopCameras[_desktopCameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
      );

      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      await _desktopCameraController?.dispose();
      _desktopCameraController = controller;

      setState(() {
        _desktopCameraReady = true;
        _cameraError = null;
        _cameraInfo = 'Camera ready. Point it at the QR code.';
      });

      _startDesktopScanLoop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _desktopCameraReady = false;
        _cameraInfo = null;
        _cameraError = _buildCameraErrorMessage(e);
      });
    } finally {
      _cameraStarting = false;
      if (mounted) setState(() {});
    }
  }

  void _startDesktopScanLoop() {
    _desktopScanTimer?.cancel();
    _desktopScanTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _captureAndAnalyzeDesktopFrame();
    });
  }

  Future<void> _captureAndAnalyzeDesktopFrame() async {
    final controller = _desktopCameraController;
    if (!_isDesktopPlatform ||
        _desktopAnalyzing ||
        _processing ||
        !_desktopCameraReady ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    _desktopAnalyzing = true;
    try {
      final shot = await controller.takePicture();
      await _controller.analyzeImage(shot.path);
      try {
        final f = File(shot.path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    } catch (e) {
      debugPrint('Desktop frame scan failed: $e');
    } finally {
      _desktopAnalyzing = false;
    }
  }

  Future<void> _switchDesktopCamera() async {
    if (_switchingCamera) return;
    if (_desktopCameras.isEmpty) {
      await _initDesktopCamera();
      return;
    }

    _switchingCamera = true;
    try {
      final next = (_desktopCameraIndex + 1) % _desktopCameras.length;
      await _initDesktopCamera(forcedIndex: next);
    } finally {
      _switchingCamera = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _desktopScanTimer?.cancel();
    _desktopBarcodeSub?.cancel();
    _desktopCameraController?.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final first = barcodes.first;
    final code = (first.rawValue ?? first.displayValue)?.trim();
    if (code == null || code.isEmpty) return;

    debugPrint('🧾 Bin QR scanned value: $code');

    setState(() {
      _processing = true;
      _error = null;
      _cameraInfo = null;
    });

    final firestore = context.read<FirestoreService>();
    final bin = await firestore.getBin(code);
    if (!mounted) return;
    if (bin != null) {
      widget.onScanned(bin.binId);
    } else {
      final shouldAdd = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Bin Not Found'),
              content: Text('Add this QR as a new bin?\n\nBin ID: $code'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Add Bin'),
                ),
              ],
            ),
          ) ??
          false;

      if (!mounted) return;
      if (shouldAdd) {
        await firestore.setBin(
          BinModel(
            binId: code,
            qrCode: code,
            locationName: 'User Added Bin',
          ),
        );
        if (!mounted) return;
        widget.onScanned(code);
      } else {
        setState(() {
          _error = 'Unknown bin. Please scan a registered bin QR code.';
          _processing = false;
        });
      }
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
          if (_isDesktopPlatform)
            if (_desktopCameraReady && _desktopCameraController != null)
              SizedBox.expand(child: CameraPreview(_desktopCameraController!))
            else
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam_off,
                      color: Colors.white,
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Laptop camera unavailable.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _cameraError ?? 'Please allow camera access and retry.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              )
          else
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error, child) {
                if (_cameraError == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() {
                      _cameraError = _buildCameraErrorMessage(error);
                    });
                  });
                }

                return Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.videocam_off,
                        color: Colors.white,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Camera is unavailable.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _cameraError ?? 'Please allow camera permission and try again.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (_cameraStarting)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          Positioned(
            right: 16,
            top: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _switchingCamera ? null : _switchCameraManually,
                  icon: const Icon(Icons.cameraswitch, color: Colors.white, size: 18),
                  label: Text(
                    _switchingCamera ? 'Switching...' : 'Switch',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _cameraStarting ? null : _retryCamera,
                  icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
                  label: Text(
                    _cameraStarting ? 'Starting...' : 'Retry',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          if (_cameraInfo != null && _cameraError == null)
            Positioned(
              left: 24,
              right: 24,
              top: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _cameraInfo!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
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