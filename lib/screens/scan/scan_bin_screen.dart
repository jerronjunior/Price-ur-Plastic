import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../../services/bin_detector.dart';
import '../../services/camera_service.dart';
import '../../services/training_data_service.dart';

export '../../services/bin_detector.dart' show BinType;

extension BinTypeX on BinType {
  String get storageValue {
    switch (this) {
      case BinType.cocaCola:    return 'coca_cola';
      case BinType.keells:      return 'keells';
      case BinType.ecoSpindles: return 'eco_spindles';
      case BinType.unknown:     return 'unknown';
    }
  }

  Color get color {
    switch (this) {
      case BinType.cocaCola:    return const Color(0xFFE53935);
      case BinType.keells:      return const Color(0xFF2E7D32);
      case BinType.ecoSpindles: return const Color(0xFF6A1B9A);
      case BinType.unknown:     return Colors.white38;
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ScanBinScreen
// ══════════════════════════════════════════════════════════════════════════════
class ScanBinScreen extends StatefulWidget {
  const ScanBinScreen({
    super.key,
    required this.onScanned,
    required this.onBack,
  });

  final void Function(String binType) onScanned;
  final VoidCallback onBack;

  @override
  State<ScanBinScreen> createState() => _ScanBinScreenState();
}

class _ScanBinScreenState extends State<ScanBinScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  CameraController? _cam;
  bool _cameraReady     = false;
  bool _processingFrame = false;
  int  _frameCount      = 0;
  bool _confirmed       = false;
  bool _cameraStarting  = false; // guards re-entrant _initCamera() calls

  final BinDetector _detector = BinDetector();
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // The OS can force-close the camera hardware while the app is
    // backgrounded — reusing that controller on resume leaves the preview
    // permanently black/stuck, so always tear down and reopen fresh.
    if (s == AppLifecycleState.inactive || s == AppLifecycleState.paused) {
      _teardownCamera();
    } else if (s == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _teardownCamera() async {
    final cam = _cam;
    _cam = null;
    if (mounted) setState(() => _cameraReady = false);
    if (cam != null) {
      try {
        if (cam.value.isStreamingImages) await cam.stopImageStream();
      } catch (_) {}
      try {
        await cam.dispose();
      } catch (_) {}
    }
  }

  Future<void> _initCamera() async {
    if (_cameraStarting) return;
    _cameraStarting = true;
    try {
      final camera = await CameraService.getBackCamera();
      if (camera == null || !mounted) return;
      final cam = CameraController(
        camera, ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      _cam = cam;
      try {
        await cam.initialize();
        if (!mounted || _cam != cam) return; // torn down while awaiting
        setState(() => _cameraReady = true);
        await cam.startImageStream(_onFrame);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Camera error: $e')));
      }
    } finally {
      _cameraStarting = false;
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _confirmed) return;
    _processingFrame = true;
    try {
      _detector.update(image);
      if (mounted) setState(() {});
      if (_detector.hasDetection) _proceed(_detector.detectedType);
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _proceed(BinType type) async {
    if (_confirmed) return;
    _confirmed = true;
    await _cam?.stopImageStream();
    if (!mounted) return;

    // ── Collect training data (background, never blocks the UI) ────────────
    // Captures a still photo of the confirmed bin and uploads it so the
    // bin-color model can be retrained from real, in-the-field detections.
    unawaited(_saveBinTrainingSample(type));

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Row(children: [
        Icon(Icons.check_circle, color: Colors.white, size: 18),
        SizedBox(width: 8),
        Text('Bin detected!'),
      ]),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(milliseconds: 700),
    ));

    await Future.delayed(const Duration(milliseconds: 450));
    if (mounted) widget.onScanned(type.storageValue);
  }

  // ── Capture + upload a training sample for this confirmed bin ────────────
  // Runs after the stream is stopped so takePicture() doesn't conflict
  // with the active image stream. Never throws into the UI — training
  // data collection must never break the actual scanning flow.
  Future<void> _saveBinTrainingSample(BinType type) async {
    try {
      final photo = await _cam?.takePicture();
      if (photo == null) return;
      await TrainingDataService().onBinColorConfirmed(
        imagePath: photo.path,
        binType:   type.storageValue,
        confidence: 1.0, // passed all 5 detection checks — high confidence
      );
    } catch (e) {
      // Training capture failing should never affect the scan result.
      debugPrint('[Training] bin sample capture failed: $e');
    }
  }

  String get _statusText {
    if (!_detector.passedShape && _detector.colorCells > 0) {
      return 'Move closer — get the whole bin in frame';
    }
    if (_detector.colorCells > 0 && _detector.darkSlotCells < 4) {
      return 'Show the bin slot / opening';
    }
    return 'Point camera at the bin';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
        centerTitle: true,
        title: const Text('Scan Bin',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w500)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF67E8A8)));
    }

    return LayoutBuilder(builder: (ctx, box) {
      final Size  size   = Size(box.maxWidth, box.maxHeight);
      final bool  locked = _detector.hasDetection;
      final Color ring   = locked
          ? _detector.detectedType.color
          : _detector.colorCells > 0 && _detector.passedShape
              ? Colors.orange
              : Colors.white38;

      return Stack(fit: StackFit.expand, children: [

        // Camera
        Positioned.fill(child: CameraPreview(_cam!)),
        Container(color: Colors.black.withValues(alpha: 0.10)),

        // Pulsing viewfinder ring
        Center(
          child: AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) {
              final double p = _pulseCtrl.value;
              return Container(
                width:  size.width * 0.82,
                height: size.width * 0.82,
                decoration: BoxDecoration(
                  shape:  BoxShape.circle,
                  border: Border.all(
                    color: ring.withValues(
                        alpha: locked ? 0.88 + p * 0.12 : 0.45),
                    width: locked ? 4.5 : 2.0,
                  ),
                  boxShadow: locked
                      ? [BoxShadow(
                          color: _detector.detectedType.color
                              .withValues(alpha: 0.30 + p * 0.20),
                          blurRadius: 24 + p * 12,
                          spreadRadius: 3,
                        )]
                      : null,
                ),
              );
            },
          ),
        ),

        // Corner brackets
        Positioned(
          left:   size.width  * 0.09,
          top:    size.height * 0.10,
          right:  size.width  * 0.09,
          bottom: size.height * 0.26,
          child: CustomPaint(
            painter: _CornerPainter(color: ring, isLocked: locked),
          ),
        ),

        // Status badge
        Positioned(
          top: 18, left: 0, right: 0,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: locked
                  ? Container(
                      key: const ValueKey('locked'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.shade700,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle,
                              color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Text('Bin confirmed!',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    )
                  : Container(
                      key: ValueKey(_statusText),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.60),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(_statusText,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                    ),
            ),
          ),
        ),

        // Bottom instruction — SafeArea prevents overflow
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Show the whole bin clearly.\nThe slot opening must be visible.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.45),
                ),
              ),
            ),
          ),
        ),
      ]);
    });
  }
}

class _CornerPainter extends CustomPainter {
  const _CornerPainter({required this.color, required this.isLocked});
  final Color color;
  final bool  isLocked;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color      = color
      ..style      = PaintingStyle.stroke
      ..strokeWidth = isLocked ? 3.5 : 2.0
      ..strokeCap  = StrokeCap.round;

    const double arm = 24.0;
    final double w = size.width, h = size.height;

    canvas.drawLine(const Offset(0, arm), const Offset(0, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(arm, 0), paint);
    canvas.drawLine(Offset(w - arm, 0), Offset(w, 0), paint);
    canvas.drawLine(Offset(w, 0), Offset(w, arm), paint);
    canvas.drawLine(Offset(0, h - arm), Offset(0, h), paint);
    canvas.drawLine(Offset(0, h), Offset(arm, h), paint);
    canvas.drawLine(Offset(w, h - arm), Offset(w, h), paint);
    canvas.drawLine(Offset(w, h), Offset(w - arm, h), paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) =>
      old.color != color || old.isLocked != isLocked;
}