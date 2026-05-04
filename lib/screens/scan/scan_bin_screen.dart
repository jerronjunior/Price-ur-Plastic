import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

enum BinType {
  cocaCola,
  cargills,
  keells,
  ecoSpindles,
  unknown,
}

extension BinTypeX on BinType {
  String get displayName {
    switch (this) {
      case BinType.cocaCola:    return 'Coca-Cola Give Back Life';
      case BinType.cargills:    return 'Cargills Food City';
      case BinType.keells:      return 'Keells Plasticcycle';
      case BinType.ecoSpindles: return 'Eco Spindles';
      case BinType.unknown:     return 'Unknown Bin';
    }
  }

  Color get color {
    switch (this) {
      case BinType.cocaCola:    return const Color(0xFFE53935);
      case BinType.cargills:    return const Color(0xFFC62828);
      case BinType.keells:      return const Color(0xFF2E7D32);
      case BinType.ecoSpindles: return const Color(0xFF6A1B9A);
      case BinType.unknown:     return Colors.white38;
    }
  }

  String get emoji {
    switch (this) {
      case BinType.cocaCola:
      case BinType.cargills:    return '🔴';
      case BinType.keells:      return '🟢';
      case BinType.ecoSpindles: return '🟣';
      case BinType.unknown:     return '⚪';
    }
  }

  String get storageValue {
    switch (this) {
      case BinType.cocaCola:    return 'coca_cola';
      case BinType.cargills:    return 'cargills';
      case BinType.keells:      return 'keells';
      case BinType.ecoSpindles: return 'eco_spindles';
      case BinType.unknown:     return 'unknown';
    }
  }
}

class _BinColorDetector {
  static const int _cols     = 12;
  static const int _rows     = 9;
  static const int _minCells = 8;
  static const int _lockFrames = 6;

  int     _streak     = 0;
  bool    _locked     = false;
  BinType _lockedType = BinType.unknown;

  BinType detectedType = BinType.unknown;
  bool    hasDetection = false;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;

    final Uint8List  yPlane  = image.planes[0].bytes;
    final Uint8List? uPlane  = image.planes.length > 1 ? image.planes[1].bytes : null;
    final Uint8List? vPlane  = image.planes.length > 2 ? image.planes[2].bytes : null;
    final int uStride = image.planes.length > 1 ? image.planes[1].bytesPerRow : fw ~/ 2;
    final int vStride = image.planes.length > 2 ? image.planes[2].bytesPerRow : fw ~/ 2;

    final int cellW = fw ~/ _cols;
    final int cellH = fh ~/ _rows;

    int rCells = 0, gCells = 0, pCells = 0;

    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        final int x0 = col * cellW;
        final int y0 = row * cellH;
        final int x1 = (x0 + cellW).clamp(0, fw);
        final int y1 = (y0 + cellH).clamp(0, fh);

        double sumY = 0, sumU = 0, sumV = 0;
        int cnt = 0;

        for (int py = y0; py < y1; py += 6) {
          for (int px = x0; px < x1; px += 6) {
            final int yi = py * fw + px;
            if (yi >= yPlane.length) continue;
            sumY += yPlane[yi];
            if (uPlane != null && vPlane != null) {
              final int ui = (py ~/ 2) * uStride + (px ~/ 2);
              final int vi = (py ~/ 2) * vStride + (px ~/ 2);
              if (ui < uPlane.length) sumU += uPlane[ui];
              if (vi < vPlane.length) sumV += vPlane[vi];
            }
            cnt++;
          }
        }

        if (cnt == 0) continue;
        final double mY = sumY / cnt;
        final double mU = uPlane != null ? sumU / cnt : 128;
        final double mV = vPlane != null ? sumV / cnt : 128;

        // Red — Coca-Cola / Cargills
        if (mY >= 40 && mY <= 130 && mV >= 155 && mV <= 215 && mU >= 70 && mU <= 120) {
          rCells++;
        }
        // Green — Keells
        else if (mY >= 40 && mY <= 145 && mV >= 80 && mV <= 128 && mU >= 135 && mU <= 190) {
          gCells++;
        }
        // Purple — Eco Spindles
        else if (mY >= 20 && mY <= 88 && mV >= 105 && mV <= 138 && mU >= 125 && mU <= 162) {
          pCells++;
        }
      }
    }

    BinType winner  = BinType.unknown;
    int     maxCells = _minCells - 1;
    if (rCells > maxCells) { maxCells = rCells; winner = BinType.cocaCola; }
    if (gCells > maxCells) { maxCells = gCells; winner = BinType.keells; }
    if (pCells > maxCells) {                    winner = BinType.ecoSpindles; }

    if (winner != BinType.unknown) {
      if (winner == _lockedType || !_locked) {
        _streak = (_streak + 1).clamp(0, _lockFrames + 1);
        _lockedType = winner;
      } else {
        _streak = 1; _lockedType = winner; _locked = false;
      }
      if (_streak >= _lockFrames && !_locked) _locked = true;
      detectedType = _lockedType;
      hasDetection = _locked;
    } else {
      _streak = (_streak - 1).clamp(0, _lockFrames);
      if (_streak == 0) {
        _locked = false; _lockedType = BinType.unknown;
        detectedType = BinType.unknown; hasDetection = false;
      }
    }
  }

  void reset() {
    _streak = 0; _locked = false; _lockedType = BinType.unknown;
    detectedType = BinType.unknown; hasDetection = false;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ScanBinScreen — point camera at bin → auto-detected → go to next screen
// No confirmation sheet. No bin brand shown. Just scan and proceed.
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
    with TickerProviderStateMixin {
  CameraController? _cam;
  bool _cameraReady     = false;
  bool _processingFrame = false;
  int  _frameCount      = 0;
  bool _confirmed       = false;

  final _BinColorDetector _detector = _BinColorDetector();

  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _initCamera();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _cam?.stopImageStream();
    _cam?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cam = CameraController(
      camera, ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await _cam!.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
      await _cam!.startImageStream(_onFrame);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _confirmed) return;
    _processingFrame = true;
    try {
      _detector.update(image);
      if (mounted) setState(() {});

      // ── Auto-proceed as soon as a bin is locked ──────────────────────────
      // No confirmation sheet — just go straight to the next screen
      if (_detector.hasDetection && _detector.detectedType != BinType.unknown) {
        _proceed(_detector.detectedType);
      }
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _proceed(BinType type) async {
    if (_confirmed) return;
    _confirmed = true;
    await _cam?.stopImageStream();
    if (!mounted) return;

    // Small success flash then navigate
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Text('Bin detected!'),
      ]),
      backgroundColor: Colors.green.shade700,
      duration: const Duration(milliseconds: 800),
    ));

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) widget.onScanned(type.storageValue);
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
          : Colors.white38;

      return Stack(fit: StackFit.expand, children: [

        // Camera
        Positioned.fill(child: CameraPreview(_cam!)),
        Container(color: Colors.black.withValues(alpha: 0.12)),

        // ── Pulsing circle ──────────────────────────────────────────────
        Center(
          child: AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, __) {
              final double p = _pulseCtrl.value;
              return Container(
                width:  size.width * 0.78,
                height: size.width * 0.78,
                decoration: BoxDecoration(
                  shape:  BoxShape.circle,
                  border: Border.all(
                    color: ring.withValues(
                        alpha: locked ? 0.85 + p * 0.15 : 0.40),
                    width: locked ? 4.0 : 2.0,
                  ),
                  boxShadow: locked
                      ? [BoxShadow(
                          color: _detector.detectedType.color
                              .withValues(alpha: 0.25 + p * 0.15),
                          blurRadius: 22 + p * 10,
                          spreadRadius: 2,
                        )]
                      : null,
                ),
              );
            },
          ),
        ),

        // ── Corner brackets ─────────────────────────────────────────────
        Positioned(
          left:   size.width  * 0.11,
          top:    size.height * 0.12,
          right:  size.width  * 0.11,
          bottom: size.height * 0.28,
          child: CustomPaint(
            painter: _CornerPainter(color: ring, isLocked: locked),
          ),
        ),

        // ── Status badge ────────────────────────────────────────────────
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
                          Text('Bin found!',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    )
                  : Container(
                      key: const ValueKey('scanning'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.60),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('Point camera at the bin…',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 13)),
                    ),
            ),
          ),
        ),

        // ── Bottom instruction — fixed with SafeArea to avoid overflow ──
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
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Hold the camera steady in front of the bin.\nDetection is automatic.',
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

// ── Corner bracket painter (unchanged) ───────────────────────────────────────
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

    const double arm = 22.0;
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