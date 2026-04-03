import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart' hide BarcodeFormat;

import '../../services/bottle_tflite_service.dart';

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
  Timer? _mobileScanTimer;

  final BottleTfliteService _tflite = BottleTfliteService();

  bool _cameraReady = false;
  bool _isScanningFrame = false;
  bool _processing = false;
  bool _isProcessingDesktopScan = false;
  bool _isBottleConfirmed = false;
  bool _tfliteReady = false;
  bool _navigating = false;

  int _bottleDetectionStreak = 0;
  String? _error;
  String _detectedLabel = '';

  // ── Anti-spoof: liveness detection ──────────────────────────────────────────
  // Strategy: capture a tiny brightness fingerprint (mean luminance of a
  // 32×32 thumbnail) from each frame while the streak builds.
  //
  // Real bottle held by hand → micro-tremor & natural lighting variation
  //   → brightness changes slightly each frame → stdDev HIGH → PASS ✅
  //
  // Flat photo / screen image held still → identical pixels every frame
  //   → brightness barely changes → stdDev LOW → REJECT ❌
  //
  // No new packages needed — uses dart:ui which ships with Flutter.

  /// Streak length before confirming (raised from 3 → 5 for enough samples).
  static const int _requiredStreak = 5;

  /// Minimum brightness std-dev across streak frames to pass.
  /// Real hand-held: ~2–8.  Flat photo/screen: ~0–1.2.
  static const double _livenessMinStdDev = 2;

  final List<double> _brightnessHistory = [];
  bool _livenessRejected = false;
  // ────────────────────────────────────────────────────────────────────────────

  bool get _isDesktopPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _tflite.init();
    if (!mounted) return;
    setState(() => _tfliteReady = _tflite.isReady);

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

      _cameraController = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await _cameraController!.initialize();

      if (!mounted) return;
      setState(() => _cameraReady = true);

      _mobileScanTimer?.cancel();
      _mobileScanTimer = Timer.periodic(
        const Duration(milliseconds: 1500),
        (_) => _scanMobileFrame(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Camera init failed. Please retry.');
      debugPrint('Mobile camera init error: $e');
    }
  }

  // ── Liveness helper: mean luminance of a 32×32 thumbnail ────────────────────
  Future<double> _computeMeanBrightness(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 32, targetHeight: 32);
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (byteData == null) return 0;

      final pixels = byteData.buffer.asUint8List();
      double sum = 0;
      int count = 0;
      for (int i = 0; i + 3 < pixels.length; i += 4) {
        // ITU-R BT.709 perceived luminance
        sum += pixels[i] * 0.2126 + pixels[i + 1] * 0.7152 + pixels[i + 2] * 0.0722;
        count++;
      }
      return count > 0 ? sum / count : 0;
    } catch (e) {
      debugPrint('Brightness error: $e');
      return 0;
    }
  }

  double _stdDev(List<double> values) {
    if (values.length < 2) return 0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / values.length;
    return sqrt(variance);
  }
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _scanMobileFrame() async {
    if (_isDesktopPlatform ||
        _isScanningFrame ||
        _processing ||
        _navigating ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) return;

    _isScanningFrame = true;
    String? imagePath;

    try {
      final shot = await _cameraController!.takePicture();
      imagePath = shot.path;

      // ── No TFLite model → skip to insertion ──────────────────────────────
      if (!_tfliteReady) {
        setState(() {
          _isBottleConfirmed = true;
          _error = 'AI model missing. Skipping to insertion check.';
          _detectedLabel = 'Model missing';
        });
        await _goToInsertionCheck();
        return;
      }

      final tflite = await _tflite.detectFromFilePath(imagePath);
      if (!mounted) return;

      // ── TFLite says no bottle → reset ────────────────────────────────────
      if (!tflite.isBottle) {
        _bottleDetectionStreak = 0;
        _brightnessHistory.clear();
        _livenessRejected = false;
        setState(() {
          _isBottleConfirmed = false;
          _detectedLabel = tflite.label;
          _error = 'No bottle detected (${tflite.label}).';
        });
        return;
      }

      // ── TFLite says bottle → liveness check ──────────────────────────────

      // Step 1: Record brightness fingerprint for this frame
      final brightness = await _computeMeanBrightness(imagePath);
      _brightnessHistory.add(brightness);
      if (_brightnessHistory.length > _requiredStreak) _brightnessHistory.removeAt(0);

      _bottleDetectionStreak += 1;
      setState(() {
        _detectedLabel = tflite.label;
        _livenessRejected = false;
      });

      // Step 2: Still collecting — keep scanning
      if (_bottleDetectionStreak < _requiredStreak) {
        setState(() {
          _isBottleConfirmed = false;
          _error = 'Verifying real bottle… ($_bottleDetectionStreak/$_requiredStreak)';
        });
        return;
      }

      // Step 3: Streak complete → apply liveness gate
      final stdDev = _stdDev(_brightnessHistory);
      debugPrint('[Liveness] stdDev=$stdDev threshold=$_livenessMinStdDev');

      if (stdDev < _livenessMinStdDev) {
        // FAKE: brightness was identical across all frames → flat photo/image
        _bottleDetectionStreak = 0;
        _brightnessHistory.clear();
        setState(() {
          _isBottleConfirmed = false;
          _livenessRejected = true;
          _error = 'Please use a real bottle, not a photo or screen image.';
        });
        return;
      }

      // Step 4: All checks passed ✅
      _brightnessHistory.clear();
      setState(() {
        _isBottleConfirmed = true;
        _livenessRejected = false;
        _error = null;
      });
      await _goToInsertionCheck();

    } catch (e) {
      debugPrint('Mobile scan frame error: $e');
    } finally {
      if (imagePath != null) {
        try {
          final f = File(imagePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      _isScanningFrame = false;
    }
  }

  Future<void> _goToInsertionCheck() async {
    if (_navigating || !mounted) return;
    _navigating = true;
    setState(() => _processing = true);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    widget.onScanned('bottle-confirmed');
  }

  Future<void> _onDesktopDetect(BarcodeCapture capture) async {
    if (_isProcessingDesktopScan || _processing || _navigating) return;

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
      await _goToInsertionCheck();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Scan failed. Please try again.';
        _processing = false;
        _isBottleConfirmed = false;
      });
      debugPrint('Desktop scan error: $e');
    } finally {
      _isProcessingDesktopScan = false;
    }
  }

  Future<void> _reloadApiIntegration() async {
    if (_processing || !mounted) return;
    setState(() {
      _processing = true;
      _error = null;
      _isBottleConfirmed = false;
      _bottleDetectionStreak = 0;
      _brightnessHistory.clear();
      _livenessRejected = false;
      _detectedLabel = '';
      _navigating = false;
    });

    try {
      await _tflite.init();
      if (_isDesktopPlatform) {
        try { await _desktopScannerController?.stop(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
        try { await _desktopScannerController?.start(); } catch (_) {}
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
      debugPrint('Reload integration error: $e');
    }
  }

  @override
  void dispose() {
    _mobileScanTimer?.cancel();
    _cameraController?.dispose();
    _desktopScannerController?.dispose();
    _tflite.dispose();
    super.dispose();
  }

  double _getScanOutlineSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return ((width < height ? width : height) * 0.75).clamp(280.0, 500.0);
  }

  @override
  Widget build(BuildContext context) {
    final isNonBottleError = (_error ?? '').toLowerCase().contains('no bottle');

    final frameColor = _livenessRejected
        ? Colors.red
        : (!_isBottleConfirmed && isNonBottleError)
            ? Colors.red
            : _isBottleConfirmed
                ? Colors.green
                : const Color(0xFF1565C0);

    String statusText;
    if (!_tfliteReady) {
      statusText = 'AI model missing. Going to insertion check';
    } else if (_isBottleConfirmed) {
      statusText = 'Bottle confirmed. Moving to insertion check';
    } else if (_livenessRejected) {
      statusText = 'Please hold a real bottle in front of the camera';
    } else {
      statusText = 'Point camera at a plastic bottle';
    }

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
                    style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
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
                // Camera preview
                if (_isDesktopPlatform && _desktopScannerController != null)
                  MobileScanner(controller: _desktopScannerController!, onDetect: _onDesktopDetect)
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
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 12),
                        Text('Starting camera...', style: TextStyle(color: Colors.white)),
                      ]),
                    ),
                  ),

                // Scan box outline
                Center(
                  child: Builder(builder: (context) {
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
                  }),
                ),

                // Liveness progress dots
                if (_bottleDetectionStreak > 0 &&
                    _bottleDetectionStreak < _requiredStreak &&
                    !_livenessRejected)
                  Positioned(
                    bottom: 130,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.verified_user, color: Colors.white70, size: 14),
                            const SizedBox(width: 8),
                            const Text('Liveness check ',
                                style: TextStyle(color: Colors.white70, fontSize: 12)),
                            ...List.generate(
                              _requiredStreak,
                              (i) => Container(
                                width: 10, height: 10,
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i < _bottleDetectionStreak
                                      ? Colors.green
                                      : Colors.white24,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Processing overlay
                if (_processing)
                  Container(
                    color: Colors.black38,
                    child: const Center(child: CircularProgressIndicator(color: Colors.white)),
                  ),

                // Status text + error banner
                Positioned(
                  bottom: 60, left: 0, right: 0,
                  child: Column(
                    children: [
                      Text(
                        statusText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                      if (_detectedLabel.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Detector: $_detectedLabel',
                            style: const TextStyle(
                              color: Colors.white70, fontSize: 12,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                            )),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 24),
                        _StatusBanner(
                          color: _livenessRejected
                              ? Colors.purple.shade700
                              : isNonBottleError
                                  ? Colors.orange.shade800
                                  : Colors.red.shade700,
                          icon: _livenessRejected
                              ? Icons.pan_tool
                              : isNonBottleError
                                  ? Icons.no_drinks
                                  : Icons.error,
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
          boxShadow: [BoxShadow(color: Colors.grey.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, -2))],
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _BottomNavItem(icon: Icons.home, label: 'Home', isActive: false, onTap: () => context.push('/home')),
            _BottomNavItem(icon: Icons.leaderboard, label: 'Leaderboard', isActive: false, onTap: () => context.push('/leaderboard')),
            _BottomNavItem(icon: Icons.camera_alt, label: 'Scan', isActive: true, onTap: () {}),
            _BottomNavItem(icon: Icons.card_giftcard, label: 'Rewards', isActive: false, onTap: () => context.push('/rewards')),
            _BottomNavItem(icon: Icons.person, label: 'Profile', isActive: false, onTap: () => context.push('/profile')),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.color, required this.icon, required this.message});
  final Color color;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(message,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({required this.icon, required this.label, required this.isActive, required this.onTap});
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
          Icon(icon, color: isActive ? primaryBlue : Colors.grey.shade700, size: 24),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                fontSize: 10,
                color: isActive ? primaryBlue : Colors.grey.shade700,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              )),
        ],
      ),
    );
  }
}