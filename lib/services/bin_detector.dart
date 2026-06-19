import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

enum BinType { cocaCola, keells, ecoSpindles, unknown }

/// Shape + color + wire-mesh validation for Sri Lankan recycling bins.
///
/// Calibrated from 78 reference bin photos. A frame must pass every check
/// before it counts toward the consecutive-frame lock.
class BinDetector {
  static const int _cols = 16;
  static const int _rows = 12;

  // Coverage: wire-mesh bins (Keells, Coca-Cola, Eco Spindles) have white sign
  // bands and see-through mesh — real bbox color density is typically 18–35%.
  // Texture + mesh checks remain the primary anti-spoofing layer.
  static const double _minBboxColorFraction = 0.18;
  static const double _minFrameCoverFraction = 0.09;

  // Real-world close-up shots span ~22–30% of frame height; wide-angle photos
  // of bins at slight angles push aspect ratio past 1.75.
  static const double _minHeightSpan = 0.22;
  static const int _minQuadrants = 4;

  // Slot openings in field photos are dark-gray (Y ≈ 69–82), not pitch-black.
  static const double _darkY = 82.0;
  static const int _minDarkCluster = 2;

  static const double _minTextureStd = 15.0;
  static const double _minMeshCellFraction = 0.30;
  static const double _strongMeshFraction = 0.45;
  static const double _strongMeshTexture = 19.0;

  static const int _lockFrames = 16;

  int _streak = 0;
  BinType _candidate = BinType.unknown;

  BinType detectedType = BinType.unknown;
  bool hasDetection = false;

  int colorCells = 0;
  int darkSlotCells = 0;
  bool passedShape = false;

  void update(CameraImage image) {
    final int fw = image.width;
    final int fh = image.height;

    final Uint8List yPlane = image.planes[0].bytes;
    final Uint8List? uPlane =
        image.planes.length > 1 ? image.planes[1].bytes : null;
    final Uint8List? vPlane =
        image.planes.length > 2 ? image.planes[2].bytes : null;
    final int uStride =
        image.planes.length > 1 ? image.planes[1].bytesPerRow : fw ~/ 2;
    final int vStride =
        image.planes.length > 2 ? image.planes[2].bytesPerRow : fw ~/ 2;

    final int cellW = fw ~/ _cols;
    final int cellH = fh ~/ _rows;
    const int totalCells = _cols * _rows;

    final List<BinType> cellColors =
        List.filled(totalCells, BinType.unknown);
    final List<double> cellY = List.filled(totalCells, 128);
    final List<double> cellU = List.filled(totalCells, 128);
    final List<double> cellV = List.filled(totalCells, 128);
    final List<double> cellYStd = List.filled(totalCells, 0);
    final List<double> cellMesh = List.filled(totalCells, 0);

    int rCount = 0, gCount = 0, pCount = 0;

    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        final int idx = row * _cols + col;
        final int x0 = col * cellW;
        final int y0 = row * cellH;
        final int x1 = (x0 + cellW).clamp(0, fw);
        final int y1 = (y0 + cellH).clamp(0, fh);

        double sumY = 0, sumU = 0, sumV = 0, sumY2 = 0;
        int cnt = 0;
        int meshHits = 0;
        double? prevRowY;

        for (int py = y0; py < y1; py += 4) {
          double? prevColY;
          for (int px = x0; px < x1; px += 4) {
            final int yi = py * fw + px;
            if (yi >= yPlane.length) continue;
            final double yVal = yPlane[yi].toDouble();
            sumY += yVal;
            sumY2 += yVal * yVal;
            if (uPlane != null && vPlane != null) {
              final int ui = (py ~/ 2) * uStride + (px ~/ 2);
              final int vi = (py ~/ 2) * vStride + (px ~/ 2);
              if (ui < uPlane.length) sumU += uPlane[ui];
              if (vi < vPlane.length) sumV += vPlane[vi];
            }
            if (prevColY != null && (yVal - prevColY).abs() > 18) meshHits++;
            if (prevRowY != null && (yVal - prevRowY).abs() > 18) meshHits++;
            prevColY = yVal;
            cnt++;
          }
          if (prevColY != null) prevRowY = prevColY;
        }

        if (cnt == 0) continue;

        final double mY = sumY / cnt;
        final double mU = uPlane != null ? sumU / cnt : 128;
        final double mV = vPlane != null ? sumV / cnt : 128;

        cellY[idx] = mY;
        cellU[idx] = mU;
        cellV[idx] = mV;
        cellYStd[idx] =
            cnt > 1 ? math.sqrt(math.max(0, sumY2 / cnt - mY * mY)) : 0;
        cellMesh[idx] = cnt > 0 ? meshHits / cnt : 0;

        final matched = _matchBinColor(mY, mU, mV);
        if (matched != BinType.unknown) {
          cellColors[idx] = matched;
          switch (matched) {
            case BinType.cocaCola:
              rCount++;
            case BinType.keells:
              gCount++;
            case BinType.ecoSpindles:
              pCount++;
            case BinType.unknown:
              break;
          }
        }
      }
    }

    BinType dominant = BinType.unknown;
    int domCount = 0;
    if (rCount >= gCount && rCount >= pCount) {
      dominant = BinType.cocaCola;
      domCount = rCount;
    }
    if (gCount > rCount && gCount >= pCount) {
      dominant = BinType.keells;
      domCount = gCount;
    }
    if (pCount > rCount && pCount > gCount) {
      dominant = BinType.ecoSpindles;
      domCount = pCount;
    }

    colorCells = domCount;

    final double frameCover = domCount / totalCells;
    if (dominant == BinType.unknown ||
        frameCover < _minFrameCoverFraction) {
      _miss();
      return;
    }

    int minCol = _cols, maxCol = 0, minRow = _rows, maxRow = 0;
    for (int row = 0; row < _rows; row++) {
      for (int col = 0; col < _cols; col++) {
        if (cellColors[row * _cols + col] == dominant) {
          minCol = math.min(minCol, col);
          maxCol = math.max(maxCol, col);
          minRow = math.min(minRow, row);
          maxRow = math.max(maxRow, row);
        }
      }
    }

    final int spanW = maxCol - minCol + 1;
    final int spanH = maxRow - minRow + 1;
    final int bboxCells = spanW * spanH;

    int bboxMatches = 0;
    int neutralInBbox = 0;
    double sumStd = 0;
    int stdCount = 0;
    int meshCells = 0;

    for (int row = minRow; row <= maxRow; row++) {
      for (int col = minCol; col <= maxCol; col++) {
        final int idx = row * _cols + col;
        if (cellColors[idx] == dominant) {
          bboxMatches++;
          sumStd += cellYStd[idx];
          stdCount++;
          if (cellYStd[idx] >= 12 || cellMesh[idx] >= 0.10) meshCells++;
        } else if (_isNeutralSurface(cellY[idx], cellU[idx], cellV[idx])) {
          neutralInBbox++;
        }
      }
    }

    final double bboxColorFraction =
        bboxCells > 0 ? bboxMatches / bboxCells : 0;
    final double avgTextureStd = stdCount > 0 ? sumStd / stdCount : 0;
    final double meshFraction = stdCount > 0 ? meshCells / stdCount : 0;

    if (bboxColorFraction < _minBboxColorFraction ||
        avgTextureStd < _minTextureStd ||
        meshFraction < _minMeshCellFraction) {
      _miss();
      return;
    }

    if (bboxCells > 0 && neutralInBbox / bboxCells > 0.42) {
      _miss();
      return;
    }

    final double heightFrac = spanH / _rows;
    final double aspectRatio = spanH > 0 ? spanW / spanH : 99;

    if (heightFrac < _minHeightSpan || aspectRatio > 3.0) {
      _miss();
      return;
    }

    final int midCol = (minCol + maxCol) ~/ 2;
    final int midRow = (minRow + maxRow) ~/ 2;
    int quadrantsFilled = 0;
    for (final List<int> quad in [
      [minCol, minRow, midCol, midRow],
      [midCol, minRow, maxCol, midRow],
      [minCol, midRow, midCol, maxRow],
      [midCol, midRow, maxCol, maxRow],
    ]) {
      var filled = false;
      for (int r = quad[1]; r <= quad[3] && !filled; r++) {
        for (int c = quad[0]; c <= quad[2] && !filled; c++) {
          if (cellColors[r * _cols + c] == dominant) filled = true;
        }
      }
      if (filled) quadrantsFilled++;
    }

    if (quadrantsFilled < _minQuadrants) {
      _miss();
      return;
    }

    final int slotScanMaxRow = minRow + ((maxRow - minRow) * 0.62).toInt();
    final clusterSize = _largestDarkCluster(
      minRow: minRow,
      maxRow: slotScanMaxRow,
      minCol: minCol,
      maxCol: maxCol,
      cellY: cellY,
      cellColors: cellColors,
      dominant: dominant,
    );
    final hasSignBand = _hasWhiteSignBand(
      minRow: minRow,
      maxRow: maxRow,
      minCol: minCol,
      maxCol: maxCol,
      cellY: cellY,
      cellU: cellU,
      cellV: cellV,
    );
    final strongMesh =
        meshFraction >= _strongMeshFraction && avgTextureStd >= _strongMeshTexture;

    darkSlotCells = clusterSize;
    passedShape = true;

    if (clusterSize < _minDarkCluster && !hasSignBand && !strongMesh) {
      passedShape = false;
      _miss();
      return;
    }

    if (dominant == _candidate) {
      _streak = (_streak + 1).clamp(0, _lockFrames + 1);
    } else {
      _streak = 1;
      _candidate = dominant;
    }

    if (_streak >= _lockFrames) {
      detectedType = dominant;
      hasDetection = true;
    }
  }

  /// YUV ranges from 78 reference bin photos (p10–p90, small margin).
  static BinType _matchBinColor(double mY, double mU, double mV) {
    final double uOff = mU - 128, vOff = mV - 128;
    final double rApprox = mY + 1.402 * vOff;
    final double gApprox = mY - 0.344136 * uOff - 0.714136 * vOff;
    final double bApprox = mY + 1.772 * uOff;

    final bool isGreenDominant = gApprox > rApprox * 1.24 &&
        gApprox > bApprox * 1.10 &&
        gApprox > 58;
    final bool isRedDominant = rApprox > gApprox * 1.38 &&
        rApprox > bApprox * 1.45 &&
        rApprox > 75;
    final bool isPurplish = rApprox > gApprox * 0.88 &&
        bApprox > gApprox * 0.88 &&
        rApprox < 135 &&
        mY < 120;

    if (isRedDominant &&
        mY >= 52 &&
        mY <= 145 &&
        mU >= 95 &&
        mU <= 125 &&
        mV >= 142 &&
        mV <= 235) {
      return BinType.cocaCola;
    }
    if (isGreenDominant &&
        mY >= 45 &&
        mY <= 145 &&
        mU >= 108 &&
        mU <= 138 &&
        mV >= 70 &&
        mV <= 115) {
      return BinType.keells;
    }
    if (isPurplish &&
        mY >= 65 &&
        mY <= 115 &&
        mU >= 125 &&
        mU <= 158 &&
        mV >= 130 &&
        mV <= 162) {
      return BinType.ecoSpindles;
    }
    return BinType.unknown;
  }

  static bool _isNeutralSurface(double mY, double mU, double mV) {
    final chroma = (mU - 128).abs() + (mV - 128).abs();
    return mY > 185 && chroma < 32;
  }

  /// Many Sri Lankan bins (Clean Sri Lanka, Carekleen) have a white sign band.
  static bool _hasWhiteSignBand({
    required int minRow,
    required int maxRow,
    required int minCol,
    required int maxCol,
    required List<double> cellY,
    required List<double> cellU,
    required List<double> cellV,
  }) {
    final midStart = minRow + ((maxRow - minRow) * 0.22).toInt();
    final midEnd = minRow + ((maxRow - minRow) * 0.78).toInt();

    for (int row = midStart; row <= midEnd; row++) {
      var run = 0;
      var maxRun = 0;
      for (int col = minCol; col <= maxCol; col++) {
        final idx = row * _cols + col;
        if (_isNeutralSurface(cellY[idx], cellU[idx], cellV[idx])) {
          run++;
          if (run > maxRun) maxRun = run;
        } else {
          run = 0;
        }
      }
      if (maxRun >= 4) return true;
    }
    return false;
  }

  static int _largestDarkCluster({
    required int minRow,
    required int maxRow,
    required int minCol,
    required int maxCol,
    required List<double> cellY,
    required List<BinType> cellColors,
    required BinType dominant,
  }) {
    final visited = List<bool>.filled(_cols * _rows, false);
    var largest = 0;

    bool isDark(int idx) =>
        cellY[idx] < _darkY &&
        (cellColors[idx] == dominant || cellColors[idx] == BinType.unknown);

    for (int row = minRow; row <= maxRow; row++) {
      for (int col = minCol; col <= maxCol; col++) {
        final start = row * _cols + col;
        if (visited[start] || !isDark(start)) continue;

        var size = 0;
        final stack = <int>[start];
        visited[start] = true;

        while (stack.isNotEmpty) {
          final cur = stack.removeLast();
          size++;
          final r = cur ~/ _cols;
          final c = cur % _cols;

          for (final n in [
            if (r > minRow) (r - 1) * _cols + c,
            if (r < maxRow) (r + 1) * _cols + c,
            if (c > minCol) r * _cols + (c - 1),
            if (c < maxCol) r * _cols + (c + 1),
          ]) {
            if (!visited[n] && isDark(n)) {
              visited[n] = true;
              stack.add(n);
            }
          }
        }

        if (size > largest) largest = size;
      }
    }

    return largest;
  }

  void _miss() {
    passedShape = false;
    _streak = (_streak - 1).clamp(0, _lockFrames);
    if (_streak == 0) {
      detectedType = BinType.unknown;
      hasDetection = false;
      _candidate = BinType.unknown;
    }
  }

  void reset() {
    _streak = 0;
    _candidate = BinType.unknown;
    detectedType = BinType.unknown;
    hasDetection = false;
    colorCells = 0;
    darkSlotCells = 0;
    passedShape = false;
  }
}
