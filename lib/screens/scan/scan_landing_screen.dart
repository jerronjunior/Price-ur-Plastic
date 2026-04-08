import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';
import '../../services/firestore_service.dart';
import '../../services/scan_validation_service.dart';
import '../../providers/notification_provider.dart';
import '../../models/bin_model.dart';
import 'camera_confirm_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FLOW:
//   Step 1 → Scan Bin QR    → Step 2 → Scan Bottle Barcode
//   Step 3 → Camera 10s     → Step 4 → +1 Point  OR  Try Again
// ─────────────────────────────────────────────────────────────────────────────

enum _Step { scanBin, scanBottle, cameraConfirm, success, failed }

class ScanLandingScreen extends StatefulWidget {
  const ScanLandingScreen({super.key});

  @override
  State<ScanLandingScreen> createState() => _ScanLandingScreenState();
}

class _ScanLandingScreenState extends State<ScanLandingScreen> {
  _Step _step = _Step.scanBin;
  String? _binId;
  String? _barcode;
  bool _showNotificationPanel = false;

  void _onBinScanned(String binId) =>
      setState(() { _binId = binId; _step = _Step.scanBottle; });

  void _onBottleScanned(String barcode) =>
      setState(() { _barcode = barcode; _step = _Step.cameraConfirm; });

  void _onCameraSuccess() => setState(() => _step = _Step.success);
  void _onCameraFailed()  => setState(() => _step = _Step.failed);

  void _tryAgain() => setState(() { _barcode = null; _step = _Step.scanBottle; });
  void _reset()    => setState(() { _binId = null; _barcode = null; _step = _Step.scanBin; });

  @override
  Widget build(BuildContext context) {
    // Full-screen takeovers
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    if (_step == _Step.cameraConfirm) {
      return CameraConfirmScreen(
        barcode: _barcode!,
        binId: _binId ?? '',
        onSuccess: _onCameraSuccess,
        onTimeout: _onCameraFailed,
        onBack: () => setState(() { _barcode = null; _step = _Step.scanBottle; }),
      );
    }
    if (_step == _Step.success) return _SuccessScreen(onDone: _reset);
    if (_step == _Step.failed)  return _FailedScreen(onTryAgain: _tryAgain, onReset: _reset);

    // Shared scaffold for step 1 & 2
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              _Header(onNotification: () =>
                  setState(() {
                    if (!_showNotificationPanel) {
                      context.read<NotificationProvider>().markAllAsRead();
                    }
                    _showNotificationPanel = !_showNotificationPanel;
                  }), hasUnread: hasUnread),
              _StepBar(step: _step),
              Expanded(
                child: _step == _Step.scanBin
                    ? _BinScanner(onScanned: _onBinScanned)
                    : _BottleScanner(
                        binId: _binId!,
                        onScanned: _onBottleScanned,
                        onWrongBin: _reset,
                      ),
              ),
            ],
          ),
          if (_showNotificationPanel)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _showNotificationPanel = false),
                child: Container(
                  color: Colors.black38,
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      notifications:
                          context.watch<NotificationProvider>().notifications,
                      onClose: () => setState(() => _showNotificationPanel = false),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/scan'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.onNotification, required this.hasUnread});
  final VoidCallback onNotification;
  final bool hasUnread;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.person, color: Colors.white),
              onPressed: () => context.push('/profile'),
            ),
            const Expanded(
              child: Center(
                child: Text('PuP',
                    style: TextStyle(color: Colors.white, fontSize: 26,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications, color: Colors.white),
                  if (hasUnread)
                    const Positioned(
                      right: -1,
                      top: -1,
                      child: SizedBox(
                        width: 10,
                        height: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              onPressed: onNotification,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step indicator
// ─────────────────────────────────────────────────────────────────────────────
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step});
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final binDone = step != _Step.scanBin;
    return Container(
      color: const Color(0xFF0D47A1),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
      child: Row(
        children: [
          _Dot('1', 'Scan Bin',    done: binDone,  active: step == _Step.scanBin),
          Expanded(child: Container(height: 2, color: binDone ? Colors.green : Colors.white24)),
          _Dot('2', 'Bottle',      done: false,    active: step == _Step.scanBottle),
          Expanded(child: Container(height: 2, color: Colors.white24)),
          _Dot('3', 'Insert',      done: false,    active: false),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.num, this.label, {required this.done, required this.active});
  final String num, label;
  final bool done, active;

  @override
  Widget build(BuildContext context) {
    final c = done ? Colors.green : active ? Colors.white : Colors.white30;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 13, backgroundColor: c,
          child: done
              ? const Icon(Icons.check, size: 15, color: Colors.white)
              : Text(num,
                  style: TextStyle(
                    color: active ? const Color(0xFF0D47A1) : Colors.white54,
                    fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(color: c, fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.normal)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 1 — Bin QR Scanner
// ─────────────────────────────────────────────────────────────────────────────
class _BinScanner extends StatefulWidget {
  const _BinScanner({required this.onScanned});
  final void Function(String binId) onScanned;

  @override
  State<_BinScanner> createState() => _BinScannerState();
}

class _BinScannerState extends State<_BinScanner> {
  // FIX 1: Controller created once at field level — not inside setState.
  //        Creating it inside setState/build caused it to reinitialise
  //        every frame, so onDetect never fired.
  final MobileScannerController _ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [
      BarcodeFormat.qrCode,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _active = false;    // true = scanner overlay visible
  bool _busy   = false;    // true = processing a detected code
  bool _released = false;
  String? _error;

  @override
  void dispose() {
    // Only stop stream if not already released.
    // Don't call _ctrl.dispose() here — MobileScanner widget handles
    // its own cleanup, and double-dispose causes the camera loop errors.
    if (!_released) {
      try { _ctrl.stop(); } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _releaseAndProceed(String binId) async {
    if (_released) return;
    _released = true;
    try { await _ctrl.stop(); } catch (_) {}
    // Give Android camera hardware time to fully close before next screen
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) widget.onScanned(binId);
  }

  // FIX 2: onDetect guard uses _busy flag, not _released, so it only
  //        fires once but doesn't block itself from being called.
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || _released || !_active) return;
    String? code;
    for (final b in capture.barcodes) {
      final value = (b.rawValue ?? b.displayValue)?.trim();
      if (value != null && value.isNotEmpty) {
        code = value;
        break;
      }
    }
    if (code == null || code.isEmpty) return;

    setState(() { _busy = true; _error = null; });

    try {
      final firestore = context.read<FirestoreService>();

      // Try to find the bin in Firestore
      var bin = await firestore.getBin(code).timeout(
        const Duration(seconds: 6),
        onTimeout: () => null,
      );
      if (!mounted) return;

      if (bin == null) {
        // Bin not registered yet — create it with a clean sanitised ID.
        // Sanitise: replace spaces/special chars so Firestore path is valid.
        final safeId = code.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
        final newBin = BinModel(
          binId: safeId,
          qrCode: code,
          locationName: 'Bin $safeId',
        );
        try {
          await firestore.setBin(newBin).timeout(const Duration(seconds: 6));
        } catch (writeErr) {
          // If write fails (permission), still proceed — don't block user
          debugPrint('setBin failed (non-fatal): $writeErr');
        }
        if (!mounted) return;
        bin = newBin;
      }

      await _releaseAndProceed(bin.binId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not verify bin. Please try again.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── Landing view (before tapping button) ──
    if (!_active) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Column(
          children: [
            Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.qr_code_scanner, size: 48,
                  color: Color(0xFF4CAF50)),
            ),
            const SizedBox(height: 28),
            const Text('Scan & Recycle',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0))),
            const SizedBox(height: 12),
            Text('Start by scanning the QR code on the recycling bin.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600)),
            const SizedBox(height: 44),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.qr_code, color: Colors.white),
                label: const Text('Scan Bin Barcode',
                    style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 16)),
                // FIX 4: Just set _active = true. Controller is already
                //        created and ready — no need to recreate it.
                onPressed: () => setState(() { _active = true; _error = null; }),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Scanner overlay ──
    return Stack(
      children: [
        // Camera preview — fills entire screen
        MobileScanner(
          controller: _ctrl,
          onDetect: _onDetect,
        ),

        // Semi-dark overlay on the 4 sides around the scan box
        // Using a CustomPaint instead of ColorFiltered (which causes black screen)
        Positioned.fill(
          child: _ScanOverlayPainter(
            boxSize: const Size(260, 260),
            borderColor: const Color(0xFF4CAF50),
            borderRadius: 16,
          ),
        ),

        // Animated scan line
        const Center(child: _ScanLine(color: Color(0xFF4CAF50), boxSize: 260)),

        // Status bar at bottom
        Positioned(
          bottom: 40, left: 20, right: 20,
          child: Column(
            children: [
              if (_busy)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Verifying bin...', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Point camera at the bin QR code',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center),
                ),
              ],
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() {
                  _active = false;
                  _busy = false;
                  _error = null;
                }),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white70, fontSize: 15)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step 2 — Bottle Barcode Scanner
// ─────────────────────────────────────────────────────────────────────────────
class _BottleScanner extends StatefulWidget {
  const _BottleScanner({
    required this.binId,
    required this.onScanned,
    required this.onWrongBin,
  });
  final String binId;
  final void Function(String barcode) onScanned;
  final VoidCallback onWrongBin;

  @override
  State<_BottleScanner> createState() => _BottleScannerState();
}

class _BottleScannerState extends State<_BottleScanner> {
  final MobileScannerController _ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _active   = false;
  bool _busy     = false;
  bool _released = false;
  String? _error;
  String? _confirmedCode;

  @override
  void dispose() {
    if (!_released) {
      try { _ctrl.stop(); } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _releaseAndProceed(String barcode) async {
    if (_released) return;
    _released = true;
    try { await _ctrl.stop(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) widget.onScanned(barcode);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy || _released || !_active) return;
    final code = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (code == null || code.isEmpty) return;

    setState(() { _busy = true; _error = null; });

    try {
      final firestore = context.read<FirestoreService>();
      final validation = ScanValidationService(firestore);
      final err = await validation.validateBarcode(code)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);

      if (!mounted) return;

      if (err != null) {
        setState(() { _error = err; _busy = false; });
        return;
      }

      setState(() => _confirmedCode = code);
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      await _releaseAndProceed(code);
    } catch (e) {
      // On any error still proceed — don't block the user
      if (!mounted) return;
      await _releaseAndProceed(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          children: [
            // Bin confirmed badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF4CAF50).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF4CAF50)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle,
                      color: Color(0xFF4CAF50), size: 16),
                  const SizedBox(width: 6),
                  Text('Bin: ${widget.binId}',
                      style: const TextStyle(
                          color: Color(0xFF4CAF50),
                          fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                color: const Color(0xFF1565C0).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.qr_code_2, size: 52,
                  color: Color(0xFF1565C0)),
            ),
            const SizedBox(height: 24),
            const Text('Scan the Bottle',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
                    color: Color(0xFF1565C0))),
            const SizedBox(height: 10),
            Text('Scan the barcode on the bottle you want to recycle.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600)),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.barcode_reader, color: Colors.white),
                label: const Text('Scan Bottle Barcode',
                    style: TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 16)),
                onPressed: () => setState(() { _active = true; _error = null; }),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: widget.onWrongBin,
              child: Text('Wrong bin? Scan again',
                  style: TextStyle(color: Colors.grey.shade500)),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        MobileScanner(controller: _ctrl, onDetect: _onDetect),

        Positioned.fill(
          child: _ScanOverlayPainter(
            boxSize: const Size(300, 180),
            borderColor: _confirmedCode != null
                ? Colors.green
                : const Color(0xFF1565C0),
            borderRadius: 12,
          ),
        ),

        const Center(child: _ScanLine(color: Color(0xFF1565C0), boxSize: 300)),

        Positioned(
          bottom: 40, left: 20, right: 20,
          child: Column(
            children: [
              if (_confirmedCode != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('✓ Scanned: $_confirmedCode',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                )
              else if (_busy)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Validating...',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Align bottle barcode within frame',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade700,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center),
                ),
              ],
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() {
                  _active = false;
                  _busy = false;
                  _error = null;
                  _confirmedCode = null;
                }),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white70, fontSize: 15)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan overlay: darkens area outside the scan box using CustomPainter.
// This replaces ColorFiltered+BlendMode.srcOut which causes black screen
// on many Android devices.
// ─────────────────────────────────────────────────────────────────────────────
class _ScanOverlayPainter extends StatelessWidget {
  const _ScanOverlayPainter({
    required this.boxSize,
    required this.borderColor,
    required this.borderRadius,
  });

  final Size boxSize;
  final Color borderColor;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _OverlayCustomPainter(
        boxSize: boxSize,
        borderColor: borderColor,
        borderRadius: borderRadius,
      ),
    );
  }
}

class _OverlayCustomPainter extends CustomPainter {
  _OverlayCustomPainter({
    required this.boxSize,
    required this.borderColor,
    required this.borderRadius,
  });

  final Size boxSize;
  final Color borderColor;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final darkPaint = Paint()..color = Colors.black.withOpacity(0.55);
    final clearPaint = Paint()..blendMode = BlendMode.clear;

    // Draw dark overlay over entire screen
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), darkPaint);

    // Cut out the scan box (transparent hole)
    final left   = (size.width  - boxSize.width)  / 2;
    final top    = (size.height - boxSize.height) / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, boxSize.width, boxSize.height),
      Radius.circular(borderRadius),
    );
    canvas.drawRRect(rrect, clearPaint);
    canvas.restore();

    // Draw border around scan box
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(rrect, borderPaint);

    // Draw corner accents
    _drawCorners(canvas, left, top, borderColor);
  }

  void _drawCorners(Canvas canvas, double left, double top, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 24.0;
    final r  = left;
    final b  = top;
    final rr = left + boxSize.width;
    final bb = top  + boxSize.height;

    // Top-left
    canvas.drawLine(Offset(r, b + len), Offset(r, b), paint);
    canvas.drawLine(Offset(r, b), Offset(r + len, b), paint);
    // Top-right
    canvas.drawLine(Offset(rr - len, b), Offset(rr, b), paint);
    canvas.drawLine(Offset(rr, b), Offset(rr, b + len), paint);
    // Bottom-left
    canvas.drawLine(Offset(r, bb - len), Offset(r, bb), paint);
    canvas.drawLine(Offset(r, bb), Offset(r + len, bb), paint);
    // Bottom-right
    canvas.drawLine(Offset(rr - len, bb), Offset(rr, bb), paint);
    canvas.drawLine(Offset(rr, bb), Offset(rr, bb - len), paint);
  }

  @override
  bool shouldRepaint(_OverlayCustomPainter old) =>
      old.borderColor != borderColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated scan line
// ─────────────────────────────────────────────────────────────────────────────
class _ScanLine extends StatefulWidget {
  const _ScanLine({required this.color, required this.boxSize});
  final Color color;
  final double boxSize;

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this)
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0, end: 1).animate(_ctrl);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, (widget.boxSize / 2 - 4) * (_anim.value * 2 - 1)),
        child: Container(
          width: widget.boxSize - 8,
          height: 2,
          decoration: BoxDecoration(
            color: widget.color.withOpacity(0.8),
            boxShadow: [
              BoxShadow(color: widget.color.withOpacity(0.4),
                  blurRadius: 6, spreadRadius: 2),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Success screen
// ─────────────────────────────────────────────────────────────────────────────
class _SuccessScreen extends StatefulWidget {
  const _SuccessScreen({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_SuccessScreen> createState() => _SuccessScreenState();
}

class _SuccessScreenState extends State<_SuccessScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 700), vsync: this)..forward();
    _scale = Tween<double>(begin: 0, end: 1)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _scale,
                  child: Container(
                    width: 120, height: 120,
                    decoration: const BoxDecoration(
                        color: Color(0xFF4CAF50), shape: BoxShape.circle),
                    child: const Icon(Icons.check, color: Colors.white, size: 72),
                  ),
                ),
                const SizedBox(height: 32),
                const Text('+1 Point!',
                    style: TextStyle(fontSize: 42,
                        color: Color(0xFF4CAF50), fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text('Bottle recycled successfully!',
                    style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: widget.onDone,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Done',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Failed / Try Again screen
// ─────────────────────────────────────────────────────────────────────────────
class _FailedScreen extends StatelessWidget {
  const _FailedScreen({required this.onTryAgain, required this.onReset});
  final VoidCallback onTryAgain, onReset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                      color: Colors.orange.shade100, shape: BoxShape.circle),
                  child: Icon(Icons.refresh,
                      color: Colors.orange.shade700, size: 64),
                ),
                const SizedBox(height: 32),
                Text('Bottle Not Detected',
                    style: TextStyle(fontSize: 24,
                        color: Colors.orange.shade700,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(
                  'No movement was detected at the slot in time.\n'
                  'Pass the bottle through the bin opening while the camera countdown is active.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.replay, color: Colors.white),
                    label: const Text('Try Again',
                        style: TextStyle(color: Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    onPressed: onTryAgain,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: onReset,
                  child: Text('Start over',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 15)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}