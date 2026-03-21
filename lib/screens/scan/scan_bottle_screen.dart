import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide BarcodeFormat;
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';
import '../../services/bottle_ai_service.dart';

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
  double _getScanOutlineSize(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    // Use 75% of the smallest dimension, capped at reasonable limits
    final size = (screenWidth < screenHeight ? screenWidth : screenHeight) * 0.75;
    return size.clamp(280.0, 500.0); // min 280, max 500
  }

  CameraController? _cameraController;
  MobileScannerController? _desktopScannerController;
  BarcodeScanner? _barcodeScanner;
  ImageLabeler? _imageLabeler;
  BottleAIService? _bottleAI;

  bool _cameraReady = false;
  bool _isProcessingFrame = false; // prevents concurrent ML Kit calls
  bool _processing = false;        // firestore validation in progress
  bool _isProcessingDesktopScan = false;
  bool _isBottleConfirmed = false;
  String? _error;
  String? _scannedResult;
  BottleCondition? _bottleCondition; // ← new: track bottle condition

  @override
  void initState() {
    super.initState();
    if (_isDesktopPlatform) {
      _desktopScannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      _cameraReady = true;
    } else {
      _initCamera();
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _desktopScannerController?.dispose();
    _barcodeScanner?.close();
    _imageLabeler?.close();
    _bottleAI?.dispose();
    super.dispose();
  }

  bool get _isDesktopPlatform =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Request the native format ML Kit expects per platform
      _cameraController = CameraController(
        back,
        ResolutionPreset.medium, // medium = best ML Kit performance balance
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21    // ML Kit Android expects NV21
            : ImageFormatGroup.bgra8888, // ML Kit iOS expects BGRA8888
      );

      _barcodeScanner = BarcodeScanner(formats: [BarcodeFormat.all]);
      _imageLabeler = ImageLabeler(
        options: ImageLabelerOptions(confidenceThreshold: 0.45),
      );
      _bottleAI = BottleAIService(imageLabeler: _imageLabeler);

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() => _cameraReady = true);

      // Every frame from this stream goes to _onCameraFrame
      await _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      debugPrint('❌ Camera init error: $e');
    }
  }

  Future<void> _releaseCamera() async {
    try { await _cameraController?.stopImageStream(); } catch (_) {}
    try { await _cameraController?.dispose(); } catch (_) {}
    _cameraController = null;
  }

  Future<void> _reloadApiIntegration() async {
    if (_processing || !mounted) return;

    setState(() {
      _processing = true;
      _error = null;
      _scannedResult = null;
      _isBottleConfirmed = false;
      _bottleCondition = null;
      _isProcessingFrame = false;
      _isProcessingDesktopScan = false;
    });

    try {
      if (_isDesktopPlatform) {
        try { await _desktopScannerController?.stop(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 120));
        try { await _desktopScannerController?.start(); } catch (_) {}
      } else {
        await _releaseCamera();
        await _initCamera();
      }

      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API integration reloaded. Ready to scan.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Reload failed. Please try again.';
      });
      debugPrint('⚠️ Reload integration error: $e');
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

  // ── Runs on EVERY camera frame ──────────────────────────────────────────
  Future<void> _onCameraFrame(CameraImage image) async {
    // Guard: skip if busy or done
    if (_isProcessingFrame || _processing || _scannedResult != null) return;
    _isProcessingFrame = true;

    try {
      // Convert raw camera frame to ML Kit InputImage
      final inputImage = _toInputImage(image);
      if (inputImage == null) return;

      // ── STEP 1: Bottle AI recognition (is this a bottle?) ─────────────
      final scanAnalysis = await _bottleAI!.analyzeBottle(inputImage);
      final isBottle = scanAnalysis.recognition.isBottle;

      if (!mounted) return;

      if (!isBottle) {
        setState(() {
          _isBottleConfirmed = false;
          _bottleCondition = null;
          if (!_processing) {
            _error = 'No bottle detected. Point camera at a bottle.';
          }
        });
        return;
      }

      // ── STEP 1B: Bottle condition (dropped vs non-dropped) ───────────
      final bottleCondition = scanAnalysis.condition;
      debugPrint('🍾 Bottle AI Result: $bottleCondition');

      if (!mounted) return;

      // ── STEP 2: Bottle confirmed — read barcode from same frame ───────
      if (!_isBottleConfirmed) {
        setState(() {
          _isBottleConfirmed = true;
          _bottleCondition = bottleCondition;
          _error = null;
        });
      } else {
        setState(() => _bottleCondition = bottleCondition);
      }

      final barcodes = await _barcodeScanner!.processImage(inputImage);
      if (barcodes.isEmpty) return; // bottle present but barcode not in frame yet

      final code = barcodes.first.rawValue?.trim();
      if (code == null || code.isEmpty) return;

      // ── STEP 3: Firestore validation ──────────────────────────────────
      if (!mounted || _processing) return;
      setState(() => _processing = true);

      // Pause stream during async Firestore call
      await _cameraController?.stopImageStream();

      final firestore = context.read<FirestoreService>();
      final validation = ScanValidationService(firestore);
      final err = await validation.validateBarcode(code);
      if (!mounted) return;

      if (err != null) {
        setState(() {
          _error = err;
          _processing = false;
          _isBottleConfirmed = false;
          _bottleCondition = null;
        });
        // Resume stream so user can retry
        await _cameraController?.startImageStream(_onCameraFrame);
        return;
      }

      // ── STEP 4: All good — success ────────────────────────────────────
      setState(() => _scannedResult = code);
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      await _releaseCamera();
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) widget.onScanned(code);
    } catch (e) {
      debugPrint('⚠️ Frame error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ── THE KEY: Convert CameraImage → InputImage correctly ─────────────────
  // This is what the previous approach got wrong.
  // camera package gives raw pixel planes. ML Kit needs those exact bytes
  // in the right format — NOT JPEG, not a file path.
  InputImage? _toInputImage(CameraImage image) {
    try {
      if (Platform.isIOS) {
        // iOS always gives BGRA8888 — single plane, direct pass
        final plane = image.planes.first;
        return InputImage.fromBytes(
          bytes: plane.bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.bgra8888,
            bytesPerRow: plane.bytesPerRow,
          ),
        );
      }

      // Android: we requested NV21 via imageFormatGroup.
      // NV21 has 3 planes (Y, U, V) — concatenate them all.
      final WriteBuffer buffer = WriteBuffer();
      for (final plane in image.planes) {
        buffer.putUint8List(plane.bytes);
      }

      return InputImage.fromBytes(
        bytes: buffer.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
    } catch (e) {
      debugPrint('⚠️ InputImage conversion error: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final frameColor = (!_isBottleConfirmed && _error == 'This is not a bottle')
        ? Colors.red
        : _isBottleConfirmed
            ? Colors.green
            : const Color(0xFF1565C0);

    return Scaffold(
      body: Column(
        children: [
          // ── Blue Header ───────────────────────────────────────────────
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
                    tooltip: 'Reload API integration',
                    onPressed: _reloadApiIntegration,
                  ),
                ],
              ),
            ),
          ),

          // ── Camera + Overlays ─────────────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                // Camera preview — fills entire area correctly
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
                          Text(
                            'Starting camera...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Animated scan frame — changes color by state
                Center(
                  child: Builder(
                    builder: (context) {
                      final outlineSize = _getScanOutlineSize(context);
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
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

                // Scan line
                Center(
                  child: Builder(
                    builder: (context) {
                      final outlineSize = _getScanOutlineSize(context);
                      return Container(
                        width: outlineSize,
                        height: 2,
                        color: frameColor.withValues(alpha: 0.5),
                      );
                    },
                  ),
                ),

                // Bottle confirmed badge (above frame)
                if (_isBottleConfirmed && _scannedResult == null)
                  Positioned(
                    top: MediaQuery.of(context).size.height * 0.22,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.check_circle,
                                  color: Colors.greenAccent, size: 16),
                              const SizedBox(width: 6),
                              const Text(
                                'Bottle detected',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(color: Colors.black54, blurRadius: 4),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (_bottleCondition != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: _bottleCondition!.status == 'dropped'
                                    ? Colors.orange.shade700
                                    : Colors.green.shade700,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _bottleCondition!.status == 'dropped'
                                        ? Icons.warning
                                        : Icons.check_circle,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _bottleCondition!.status == 'dropped'
                                        ? '⚠️ Dropped/Damaged (${(_bottleCondition!.confidence * 100).toStringAsFixed(0)}%)'
                                        : '✓ Non-Dropped/Intact (${(_bottleCondition!.confidence * 100).toStringAsFixed(0)}%)',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                // Firestore validation spinner
                if (_processing)
                  Container(
                    color: Colors.black38,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),

                // Bottom status
                Positioned(
                  bottom: 60,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: [
                      if (_bottleCondition?.status == 'dropped')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade700,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.orange.shade900,
                                width: 2,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.warning, color: Colors.white),
                                SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'Bottle appears damaged. Check condition before recycling.',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Text(
                        _isDesktopPlatform
                          ? (_isBottleConfirmed
                            ? 'Barcode detected. Validating...'
                            : 'Point camera at bottle barcode')
                          : (_isBottleConfirmed
                            ? 'Align the barcode within the frame'
                            : 'Point camera at a bottle'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
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
                          color: _error == 'This is not a bottle'
                              ? Colors.orange.shade800
                              : Colors.red.shade700,
                          icon: _error == 'This is not a bottle'
                              ? Icons.no_drinks
                              : Icons.error,
                          message: _error!,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _reloadApiIntegration,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reload API Integration'),
                        ),
                      ],
                      if (_isDesktopPlatform) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Desktop mode scans barcode directly.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4),
                            ],
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
            _BottomNavItem(icon: Icons.home, label: 'Home',
                isActive: false, onTap: () => context.push('/home')),
            _BottomNavItem(icon: Icons.leaderboard, label: 'Leaderboard',
                isActive: false, onTap: () => context.push('/leaderboard')),
            _BottomNavItem(icon: Icons.camera_alt, label: 'Scan',
                isActive: true, onTap: () {}),
            _BottomNavItem(icon: Icons.card_giftcard, label: 'Rewards',
                isActive: false, onTap: () => context.push('/rewards')),
            _BottomNavItem(icon: Icons.person, label: 'Profile',
                isActive: false, onTap: () => context.push('/profile')),
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
          Icon(icon,
              color: isActive ? primaryBlue : Colors.grey.shade700,
              size: 24),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                fontSize: 10,
                color: isActive ? primaryBlue : Colors.grey.shade700,
                fontWeight:
                    isActive ? FontWeight.bold : FontWeight.normal,
              )),
        ],
      ),
    );
  }
}