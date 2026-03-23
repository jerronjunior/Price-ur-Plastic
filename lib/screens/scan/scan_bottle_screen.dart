import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide BarcodeFormat;
import 'package:provider/provider.dart';

import '../../services/bottle_tflite_service.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';

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
  CameraController? _cameraController;
  MobileScannerController? _desktopScannerController;
  BarcodeScanner? _barcodeScanner;
  Timer? _mobileScanTimer;

  final BottleTfliteService _tflite = BottleTfliteService();

  bool _cameraReady = false;
  bool _isScanningFrame = false;
  bool _processing = false;
  bool _isProcessingDesktopScan = false;
  bool _isBottleConfirmed = false;
  bool _tfliteReady = false;

  int _bottleDetectionStreak = 0;
  String? _error;
  String? _scannedResult;
  String _detectedLabel = '';

  bool get _isDesktopPlatform =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _tflite.init();
    if (!mounted) return;

    setState(() {
      _tfliteReady = _tflite.isReady;
    });

    if (_isDesktopPlatform) {
      _desktopScannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      setState(() => _cameraReady = true);
      return;
    }

    await _initMobileCamera();
  }

  Future<void> _initMobileCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);
      await _cameraController!.initialize();

      if (!mounted) return;
      setState(() => _cameraReady = true);

      _mobileScanTimer?.cancel();
      _mobileScanTimer = Timer.periodic(
        const Duration(milliseconds: 1000),
        (_) => _scanMobileFrame(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Camera init failed. Please retry.';
      });
      debugPrint('❌ Mobile camera init error: $e');
    }
  }

  Future<void> _scanMobileFrame() async {
    if (_isDesktopPlatform ||
        _isScanningFrame ||
        _processing ||
        _scannedResult != null ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    _isScanningFrame = true;

    try {
      if (!_tfliteReady) {
        if (mounted) {
          setState(() {
            _isBottleConfirmed = false;
            _error = 'Model not ready. Add assets/models/ssd_mobilenet.tflite';
          });
        }
        return;
      }

      final shot = await _cameraController!.takePicture();
      final imagePath = shot.path;

      final tflite = await _tflite.detectFromFilePath(imagePath);

      if (!mounted) return;

      if (!tflite.isBottle) {
        _bottleDetectionStreak = 0;
        setState(() {
          _isBottleConfirmed = false;
          _detectedLabel = tflite.label;
          _error = 'No bottle detected (${tflite.label}).';
        });
        return;
      }

      _bottleDetectionStreak += 1;
      setState(() {
        _detectedLabel = tflite.label;
      });

      if (_bottleDetectionStreak < 3) {
        setState(() {
          _isBottleConfirmed = false;
          _error = 'Bottle candidate detected. Hold steady...';
        });
        return;
      }

      setState(() {
        _isBottleConfirmed = true;
        _error = null;
      });

      final inputImage = InputImage.fromFilePath(imagePath);
      final barcodes = await _barcodeScanner!.processImage(inputImage);
      if (barcodes.isEmpty) return;

      final code = barcodes.first.rawValue?.trim();
      if (code == null || code.isEmpty) return;

      if (!mounted || _processing) return;
      setState(() => _processing = true);

      final firestore = context.read<FirestoreService>();
      final validation = ScanValidationService(firestore);
      final err = await validation.validateBarcode(code);
      if (!mounted) return;

      if (err != null) {
        _bottleDetectionStreak = 0;
        setState(() {
          _error = err;
          _processing = false;
          _isBottleConfirmed = false;
        });
        return;
      }

      setState(() {
        _scannedResult = code;
        _processing = false;
      });

      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      widget.onScanned(code);
    } catch (e) {
      debugPrint('⚠️ Mobile scan frame error: $e');
    } finally {
      _isScanningFrame = false;
    }
  }

  Future<void> _onDesktopDetect(BarcodeCapture capture) async {
    if (_isProcessingDesktopScan || _processing || _scannedResult != null) {
      return;
    }

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final code = barcodes.first.rawValue?.trim();
    if (code == null || code.isEmpty) return;

    _isProcessingDesktopScan = true;

    try {
      if (!mounted || _processing) return;
      setState(() {
        _processing = true;
        _error = null;
        _isBottleConfirmed = true;
      });

      final firestore = context.read<FirestoreService>();
      final validation = ScanValidationService(firestore);
      final err = await validation.validateBarcode(code);
      if (!mounted) return;

      if (err != null) {
        setState(() {
          _error = err;
          _processing = false;
          _isBottleConfirmed = false;
        });
        return;
      }

      setState(() {
        _scannedResult = code;
        _processing = false;
      });
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      widget.onScanned(code);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Scan failed. Please try again.';
        _processing = false;
        _isBottleConfirmed = false;
      });
      debugPrint('⚠️ Desktop scan error: $e');
    } finally {
      _isProcessingDesktopScan = false;
    }
  }

  Future<void> _reloadApiIntegration() async {
    if (_processing || !mounted) return;

    setState(() {
      _processing = true;
      _error = null;
      _scannedResult = null;
      _isBottleConfirmed = false;
      _bottleDetectionStreak = 0;
      _detectedLabel = '';
    });

    try {
      await _tflite.init();

      if (_isDesktopPlatform) {
        try {
          await _desktopScannerController?.stop();
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          await _desktopScannerController?.start();
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _tfliteReady = _tflite.isReady;
        _processing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Reload failed. Please try again.';
      });
      debugPrint('⚠️ Reload integration error: $e');
    }
  }

  @override
  void dispose() {
    _mobileScanTimer?.cancel();
    _cameraController?.dispose();
    _desktopScannerController?.dispose();
    _barcodeScanner?.close();
    _tflite.dispose();
    super.dispose();
  }

  double _getScanOutlineSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final size = (width < height ? width : height) * 0.75;
    return size.clamp(280.0, 500.0);
  }

  @override
  Widget build(BuildContext context) {
    final isNonBottleError = (_error ?? '').toLowerCase().contains('no bottle');
    final frameColor = (!_isBottleConfirmed && isNonBottleError)
        ? Colors.red
        : _isBottleConfirmed
            ? Colors.green
            : const Color(0xFF1565C0);

    return Scaffold(
      body: Column(
        children: [
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
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: widget.onBack,
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
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    tooltip: 'Reload detection',
                    onPressed: _reloadApiIntegration,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                if (_isDesktopPlatform && _desktopScannerController != null)
                  MobileScanner(
                    controller: _desktopScannerController!,
                    onDetect: _onDesktopDetect,
                  )
                else if (_cameraReady && _cameraController != null)
                  SizedBox.expand(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _cameraController!.value.previewSize!.height,
                        height: _cameraController!.value.previewSize!.width,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  )
                else
                  const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 12),
                          Text('Starting camera...', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),

                Center(
                  child: Builder(
                    builder: (context) {
                      final outlineSize = _getScanOutlineSize(context);
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: outlineSize,
                        height: outlineSize,
                        decoration: BoxDecoration(
                          border: Border.all(color: frameColor, width: 4),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      );
                    },
                  ),
                ),

                if (_processing)
                  Container(
                    color: Colors.black38,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),

                Positioned(
                  bottom: 60,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: [
                      Text(
                        !_tfliteReady
                            ? 'TFLite model not ready. Add model files to assets/models'
                            : (_isBottleConfirmed
                                ? 'Bottle confirmed. Align barcode in frame'
                                : 'Point camera at a plastic bottle'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                      if (_detectedLabel.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Detector: $_detectedLabel',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                          ),
                        ),
                      ],
                      if (_scannedResult != null) ...[
                        const SizedBox(height: 24),
                        _StatusBanner(
                          color: Colors.green.shade700,
                          icon: Icons.check_circle,
                          message: 'Bottle scanned: $_scannedResult',
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 24),
                        _StatusBanner(
                          color: isNonBottleError
                              ? Colors.orange.shade800
                              : Colors.red.shade700,
                          icon: isNonBottleError ? Icons.no_drinks : Icons.error,
                          message: _error!,
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

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.color,
    required this.icon,
    required this.message,
  });

  final Color color;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
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
