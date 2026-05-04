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
      case BinType.cocaCola:
        return 'Coca-Cola Give Back Life';
      case BinType.cargills:
        return 'Cargills Food City';
      case BinType.keells:
        return 'Keells Plasticcycle';
      case BinType.ecoSpindles:
        return 'Eco Spindles';
      case BinType.unknown:
        return 'Unknown Bin';
    }
  }

  Color get color {
    switch (this) {
      case BinType.cocaCola:
        return const Color(0xFFE53935);
      case BinType.cargills:
        return const Color(0xFFC62828);
      case BinType.keells:
        return const Color(0xFF2E7D32);
      case BinType.ecoSpindles:
        return const Color(0xFF6A1B9A);
      case BinType.unknown:
        return Colors.grey;
    }
  }

  String get emoji {
    switch (this) {
      case BinType.cocaCola:
        return '🔴';
      case BinType.cargills:
        return '🔴';
      case BinType.keells:
        return '🟢';
      case BinType.ecoSpindles:
        return '🟣';
      case BinType.unknown:
        return '⚪';
    }
  }

  String get storageValue {
    switch (this) {
      case BinType.cocaCola:
        return 'coca_cola';
      case BinType.cargills:
        return 'cargills';
      case BinType.keells:
        return 'keells';
      case BinType.ecoSpindles:
        return 'eco_spindles';
      case BinType.unknown:
        return 'unknown';
    }
  }
}

class _BinColorDetector {
  static const int _cols = 12;
  static const int _rows = 9;
  static const int _minCells = 8;

  static const int _lockFrames = 6;
  int _streak = 0;
  bool _locked = false;
  BinType _lockedType = BinType.unknown;

  BinType detectedType = BinType.unknown;
  bool hasDetection = false;
  int redCells = 0;
  int greenCells = 0;
  int purpleCells = 0;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;

    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List? uPlane = image.planes.length > 1 ? image.planes[1].bytes : null;
    final Uint8List? vPlane = image.planes.length > 2 ? image.planes[2].bytes : null;

    final int uStride = image.planes.length > 1 ? image.planes[1].bytesPerRow : fw ~/ 2;
    final int vStride = image.planes.length > 2 ? image.planes[2].bytesPerRow : fw ~/ 2;

    final int cellW = fw ~/ _cols;
    final int cellH = fh ~/ _rows;

    int rCells = 0;
    int gCells = 0;
    int pCells = 0;

    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        final int x0 = col * cellW;
        final int y0 = row * cellH;
        final int x1 = (x0 + cellW).clamp(0, fw).toInt();
        final int y1 = (y0 + cellH).clamp(0, fh).toInt();

        double sumY = 0;
        double sumU = 0;
        double sumV = 0;
        int cnt = 0;

        for (int py = y0; py < y1; py += 6) {
          for (int px = x0; px < x1; px += 6) {
            final int yi = py * fw + px;
            if (yi >= yPlane.length) continue;

            sumY += yPlane[yi];

            if (uPlane != null && vPlane != null) {
              final int uvi = (py ~/ 2) * uStride + (px ~/ 2);
              final int vvi = (py ~/ 2) * vStride + (px ~/ 2);
              if (uvi < uPlane.length) sumU += uPlane[uvi];
              if (vvi < vPlane.length) sumV += vPlane[vvi];
            }
            cnt++;
          }
        }

        if (cnt == 0) continue;
        final double mY = sumY / cnt;
        final double mU = uPlane != null ? sumU / cnt : 128;
        final double mV = vPlane != null ? sumV / cnt : 128;

        if (mY >= 40 && mY <= 130 && mV >= 155 && mV <= 215 && mU >= 70 && mU <= 120) {
          rCells++;
        } else if (mY >= 40 && mY <= 145 && mV >= 80 && mV <= 128 && mU >= 135 && mU <= 190) {
          gCells++;
        } else if (mY >= 20 && mY <= 88 && mV >= 105 && mV <= 138 && mU >= 125 && mU <= 162) {
          pCells++;
        }
      }
    }

    redCells = rCells;
    greenCells = gCells;
    purpleCells = pCells;

    BinType winner = BinType.unknown;
    int maxCells = _minCells - 1;

    if (rCells > maxCells) {
      maxCells = rCells;
      winner = BinType.cocaCola;
    }
    if (gCells > maxCells) {
      maxCells = gCells;
      winner = BinType.keells;
    }
    if (pCells > maxCells) {
      winner = BinType.ecoSpindles;
    }

    if (winner != BinType.unknown) {
      if (winner == _lockedType || !_locked) {
        _streak = (_streak + 1).clamp(0, _lockFrames + 1).toInt();
        _lockedType = winner;
      } else {
        _streak = 1;
        _lockedType = winner;
        _locked = false;
      }

      if (_streak >= _lockFrames && !_locked) {
        _locked = true;
      }

      detectedType = _lockedType;
      hasDetection = _locked;
    } else {
      _streak = (_streak - 1).clamp(0, _lockFrames).toInt();
      if (_streak == 0) {
        _locked = false;
        _lockedType = BinType.unknown;
        detectedType = BinType.unknown;
        hasDetection = false;
      }
    }
  }

  void reset() {
    _streak = 0;
    _locked = false;
    _lockedType = BinType.unknown;
    detectedType = BinType.unknown;
    hasDetection = false;
    redCells = 0;
    greenCells = 0;
    purpleCells = 0;
  }
}

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

class _ScanBinScreenState extends State<ScanBinScreen> with TickerProviderStateMixin {
  CameraController? _cam;
  bool _cameraReady = false;
  bool _processingFrame = false;
  int _frameCount = 0;
  bool _confirmed = false;

  final _BinColorDetector _detector = _BinColorDetector();

  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
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
      camera,
      ResolutionPreset.medium,
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Camera error: $e')));
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 2 != 0 || _processingFrame || _confirmed) return;
    _processingFrame = true;
    try {
      _detector.update(image);
      if (mounted) setState(() {});

      if (_detector.hasDetection && _detector.detectedType != BinType.unknown) {
        _onBinDetected(_detector.detectedType);
      }
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _onBinDetected(BinType type) async {
    if (_confirmed) return;
    _confirmed = true;
    await _cam?.stopImageStream();

    if (!mounted) return;

    final BinType? confirmedType = await showModalBottomSheet<BinType>(
      context: context,
      isDismissible: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BinConfirmSheet(
        detectedType: type,
        onConfirm: (finalType) => Navigator.pop(context, finalType),
        onRetry: () => Navigator.pop(context),
      ),
    );

    if (!mounted) return;

    if (confirmedType != null) {
      widget.onScanned(confirmedType.storageValue);
    } else {
      _confirmed = false;
      _detector.reset();
      await _cam?.startImageStream(_onFrame);
    }
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
        title: const Text(
          'Scan Bin',
          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_cameraReady || _cam == null || !_cam!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF67E8A8)));
    }

    return LayoutBuilder(
      builder: (ctx, box) {
        final Size size = Size(box.maxWidth, box.maxHeight);
        final BinType type = _detector.detectedType;
        final bool locked = _detector.hasDetection;
        final Color ringColor = locked ? type.color : Colors.white38;

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: CameraPreview(_cam!)),
            Container(color: Colors.black.withValues(alpha: 0.12)),
            Center(
              child: AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) {
                  final double pulse = _pulseCtrl.value;
                  return Container(
                    width: size.width * 0.80,
                    height: size.width * 0.80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: ringColor.withValues(alpha: locked ? 0.85 + pulse * 0.15 : 0.40),
                        width: locked ? 4.0 : 2.0,
                      ),
                      boxShadow: locked
                          ? [
                              BoxShadow(
                                color: type.color.withValues(alpha: 0.25 + pulse * 0.15),
                                blurRadius: 20 + pulse * 10,
                                spreadRadius: 2,
                              )
                            ]
                          : null,
                    ),
                  );
                },
              ),
            ),
            Positioned(
              left: size.width * 0.10,
              top: size.height * 0.10,
              right: size.width * 0.10,
              bottom: size.height * 0.25,
              child: CustomPaint(
                painter: _CornerPainter(
                  color: locked ? type.color : Colors.white54,
                  isLocked: locked,
                ),
              ),
            ),
            Positioned(
              top: 20,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: locked
                      ? Container(
                          key: ValueKey(type),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: type.color.withValues(alpha: 0.90),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(type.emoji, style: const TextStyle(fontSize: 18)),
                              const SizedBox(width: 8),
                              Text(
                                type.displayName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Container(
                          key: const ValueKey('scanning'),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.60),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Scanning for bin...',
                            style: TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ),
                ),
              ),
            ),
            if (!locked)
              Positioned(
                bottom: 120,
                left: 24,
                right: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _cellCount('🔴', _detector.redCells, Colors.red),
                    _cellCount('🟢', _detector.greenCells, Colors.green),
                    _cellCount('🟣', _detector.purpleCells, Colors.purple),
                  ],
                ),
              ),
            Positioned(
              left: 24,
              right: 24,
              bottom: 24,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Point camera at the recycling bin',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Works with 🔴 Coca-Cola / Cargills  •  🟢 Keells  •  🟣 Eco Spindles',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cellCount(String emoji, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$emoji $count cells',
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  const _CornerPainter({required this.color, required this.isLocked});

  final Color color;
  final bool isLocked;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = isLocked ? 3.5 : 2.0
      ..strokeCap = StrokeCap.round;

    const double arm = 22.0;
    final double w = size.width;
    final double h = size.height;

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
  bool shouldRepaint(_CornerPainter old) => old.color != color || old.isLocked != isLocked;
}

class _BinConfirmSheet extends StatefulWidget {
  const _BinConfirmSheet({
    required this.detectedType,
    required this.onConfirm,
    required this.onRetry,
  });

  final BinType detectedType;
  final void Function(BinType) onConfirm;
  final VoidCallback onRetry;

  @override
  State<_BinConfirmSheet> createState() => _BinConfirmSheetState();
}

class _BinConfirmSheetState extends State<_BinConfirmSheet> {
  late BinType _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.detectedType;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Bin Detected!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Is this the correct bin? Correct it if needed.', style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 16),
          ...BinType.values.where((t) => t != BinType.unknown).map(
                (t) => _BinOption(
                  type: t,
                  selected: _selected == t,
                  onTap: () => setState(() => _selected = t),
                ),
              ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => widget.onConfirm(_selected),
              icon: const Icon(Icons.check_circle),
              label: const Text('Confirm Bin'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _selected.color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: widget.onRetry,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Scan Again'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade700,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BinOption extends StatelessWidget {
  const _BinOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final BinType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? type.color.withValues(alpha: 0.10) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? type.color : Colors.grey.shade200,
            width: selected ? 2.0 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Text(type.emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Text(
              type.displayName,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: selected ? type.color : Colors.black87,
              ),
            ),
            const Spacer(),
            if (selected) Icon(Icons.check_circle, color: type.color, size: 20),
          ],
        ),
      ),
    );
  }
}
