import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

enum BinType { cocaCola, keells, ecoSpindles, unknown }

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
// _BinDetector  v2  —  Shape + Color + Structure validation
//
// A bin is NOT just a red/green/purple region. It must pass ALL 4 checks:
//
// CHECK 1 — COLOR CLUSTER SIZE
//   The matching color must cover at least 15% of the frame.
//   A bag, label, or sign won't cover that much.
//
// CHECK 2 — VERTICAL DOMINANCE
//   The color region must be taller than it is wide (or roughly square).
//   Bins are always vertical. A bag held sideways or a horizontal banner fails.
//   Also, color region must span at least 30% of frame HEIGHT — a small
//   red sticker won't pass.
//
// CHECK 3 — COLOR UNIFORMITY (solid block, not scattered)
//   Divide the region bounding box into quadrants.
//   At least 3 out of 4 quadrants must contain matching pixels.
//   A red logo on a white bag has matching pixels in only 1 quadrant.
//   A solid red bin has matching pixels in all 4 quadrants.
//
// CHECK 4 — DARK SLOT DETECTION
//   Every Sri Lankan recycling bin has a dark opening/slot somewhere on it.
//   Scan the TOP 55% of the frame for a dark rectangular region
//   (Y < 60 = very dark = the slot hole or shadow inside the bin).
//   If no dark region is found in the color area, it's probably not a bin.
//   This is the strongest discriminator — bags, boxes, walls rarely have
//   a dark opening at the top.
//
// LOCK: requires 10 consecutive passing frames before confirming.
//       More frames = less false positives.
// ══════════════════════════════════════════════════════════════════════════════
class _BinDetector {
  // Grid for color scanning
  static const int _cols = 16;
  static const int _rows = 12;

  // Check 1: minimum % of total grid cells that must match the color
  static const double _minCoverFraction = 0.15; // 15% of frame

  // Check 2: color region must span this fraction of frame height
  static const double _minHeightSpan = 0.30;

  // Check 3: out of 4 quadrants, how many must have matching pixels
  static const int _minQuadrants = 3;

  // Check 4: dark slot — Y threshold for "dark" pixel
  static const double _darkY = 70.0;
  // Minimum dark cells in the slot scan to confirm a slot exists
  static const int _minDarkCells = 4;

  // Lock: how many consecutive passing frames before confirmed
  static const int _lockFrames = 10;

  int     _streak     = 0;
  BinType _candidate  = BinType.unknown;

  BinType detectedType = BinType.unknown;
  bool    hasDetection = false;

  // Debug info (shown as cell counts in UI)
  int colorCells    = 0;
  int darkSlotCells = 0;
  bool passedShape  = false;

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
    final int totalCells = _cols * _rows;

    // Per-cell results: which color matched, and Y mean
    final List<BinType> cellColors = List.filled(totalCells, BinType.unknown);
    final List<double>  cellY      = List.filled(totalCells, 128);

    int rCount = 0, gCount = 0, pCount = 0;

    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        final int idx = row * _cols + col;
        final int x0  = col * cellW;
        final int y0  = row * cellH;
        final int x1  = (x0 + cellW).clamp(0, fw);
        final int y1  = (y0 + cellH).clamp(0, fh);

        double sumY = 0, sumU = 0, sumV = 0;
        int cnt = 0;

        for (int py = y0; py < y1; py += 5) {
          for (int px = x0; px < x1; px += 5) {
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

        cellY[idx] = mY;

        // Red — Coca-Cola / Cargills
        if (mY >= 35 && mY <= 135 && mV >= 150 && mV <= 220 && mU >= 65 && mU <= 122) {
          cellColors[idx] = BinType.cocaCola; rCount++;
        }
        // Green — Keells
        else if (mY >= 35 && mY <= 150 && mV >= 75 && mV <= 132 && mU >= 132 && mU <= 195) {
          cellColors[idx] = BinType.keells; gCount++;
        }
        // Purple — Eco Spindles
        else if (mY >= 18 && mY <= 90 && mV >= 102 && mV <= 140 && mU >= 122 && mU <= 165) {
          cellColors[idx] = BinType.ecoSpindles; pCount++;
        }
      }
    }

    // Pick dominant color
    BinType dominant = BinType.unknown;
    int domCount = 0;
    if (rCount >= gCount && rCount >= pCount) { dominant = BinType.cocaCola;    domCount = rCount; }
    if (gCount >  rCount && gCount >= pCount) { dominant = BinType.keells;      domCount = gCount; }
    if (pCount >  rCount && pCount >  gCount) { dominant = BinType.ecoSpindles; domCount = pCount; }

    colorCells = domCount;

    // ── CHECK 1: Minimum color coverage ──────────────────────────────────────
    final double coverFraction = domCount / totalCells;
    if (dominant == BinType.unknown || coverFraction < _minCoverFraction) {
      _miss(); return;
    }

    // ── Find bounding box of matching cells ───────────────────────────────────
    int minCol = _cols, maxCol = 0, minRow = _rows, maxRow = 0;
    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        if (cellColors[row * _cols + col] == dominant) {
          if (col < minCol) minCol = col;
          if (col > maxCol) maxCol = col;
          if (row < minRow) minRow = row;
          if (row > maxRow) maxRow = row;
        }
      }
    }

    final int spanW = (maxCol - minCol + 1);
    final int spanH = (maxRow - minRow + 1);

    // ── CHECK 2: Vertical dominance + minimum height ──────────────────────────
    // spanH / _rows = fraction of frame height covered
    final double heightFrac = spanH / _rows;
    // Bins are not much wider than tall — ratio must be <= 1.8
    final double aspectRatio = spanH > 0 ? spanW / spanH : 99;

    if (heightFrac < _minHeightSpan || aspectRatio > 1.8) {
      _miss(); return;
    }

    // ── CHECK 3: Color uniformity across quadrants ────────────────────────────
    // Divide the bounding box into 4 quadrants and check each has matches
    final int midCol = (minCol + maxCol) ~/ 2;
    final int midRow = (minRow + maxRow) ~/ 2;

    int quadrantsFilled = 0;
    for (final List<int> quad in [
      [minCol, minRow, midCol,  midRow ],  // top-left
      [midCol, minRow, maxCol,  midRow ],  // top-right
      [minCol, midRow, midCol,  maxRow ],  // bottom-left
      [midCol, midRow, maxCol,  maxRow ],  // bottom-right
    ]) {
      bool filled = false;
      for (int r = quad[1]; r <= quad[3] && !filled; r++) {
        for (int c = quad[0]; c <= quad[2] && !filled; c++) {
          if (cellColors[r * _cols + c] == dominant) filled = true;
        }
      }
      if (filled) quadrantsFilled++;
    }

    if (quadrantsFilled < _minQuadrants) {
      _miss(); return;
    }

    // ── CHECK 4: Dark slot detection ─────────────────────────────────────────
    // Scan the TOP half of the matched color region for a dark area.
    // The bin slot/opening is always dark (Y < 70).
    // We look for at least 4 dark cells inside the color region's top portion.
    final int slotScanMaxRow = minRow + ((maxRow - minRow) * 0.65).toInt();
    int darkCells = 0;

    for (int row = minRow; row <= slotScanMaxRow; row++) {
      for (int col = minCol; col <= maxCol; col++) {
        final int idx = row * _cols + col;
        if (cellY[idx] < _darkY) darkCells++;
      }
    }

    darkSlotCells = darkCells;
    passedShape   = true;

    if (darkCells < _minDarkCells) {
      // No dark slot found — likely a colored bag, wall, or sign
      passedShape = false;
      _miss(); return;
    }

    // ── All 4 checks passed — this is a bin ───────────────────────────────────
    if (dominant == _candidate) {
      _streak = (_streak + 1).clamp(0, _lockFrames + 1);
    } else {
      _streak    = 1;
      _candidate = dominant;
    }

    if (_streak >= _lockFrames) {
      detectedType = dominant;
      hasDetection = true;
    }
  }

  void _miss() {
    passedShape  = false;
    _streak      = (_streak - 1).clamp(0, _lockFrames);
    if (_streak == 0) {
      detectedType = BinType.unknown;
      hasDetection = false;
      _candidate   = BinType.unknown;
    }
  }

  void reset() {
    _streak = 0; _candidate = BinType.unknown;
    detectedType = BinType.unknown; hasDetection = false;
    colorCells = 0; darkSlotCells = 0; passedShape = false;
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
    with TickerProviderStateMixin {
  CameraController? _cam;
  bool _cameraReady     = false;
  bool _processingFrame = false;
  int  _frameCount      = 0;
  bool _confirmed       = false;

  final _BinDetector _detector = _BinDetector();
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
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

  String get _statusText {
    if (!_detector.passedShape && _detector.colorCells > 0)
      return 'Move closer — get the whole bin in frame';
    if (_detector.colorCells > 0 && _detector.darkSlotCells < 4)
      return 'Show the bin slot / opening';
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