import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';
import '../../core/theme.dart';

class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen>
    with TickerProviderStateMixin {
  late AnimationController _spinController;
  late AnimationController _celebrationController;
  late Animation<double> _turnsAnimation;
  bool _showNotificationPanel = false;
  final int _spinCost = 20;
  final List<String> _prizes = [
    '50 pts',
    'Badge',
    '100 pts',
    'Star ⭐',
    '200 pts',
    'Crown 👑',
    '500 pts',
    'Gift 🎁',
  ];
  bool _isSpinning = false;
  String? _lastResult;
  double _currentTurns = 0.0;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      duration: const Duration(seconds: 5),
      vsync: this,
    );
    _celebrationController = AnimationController(
      duration: const Duration(milliseconds: 1100),
      vsync: this,
    );
    _turnsAnimation = AlwaysStoppedAnimation<double>(_currentTurns);
  }

  @override
  void dispose() {
    _spinController.dispose();
    _celebrationController.dispose();
    super.dispose();
  }

  Future<void> _spin() async {
    final user = context.read<AuthProvider>().user;
    final points = user?.totalPoints ?? 0;

    if (points < _spinCost) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not enough points. Need 20 points.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_isSpinning) return;

    final selectedIndex = math.Random().nextInt(_prizes.length);
    final selectedPrize = _prizes[selectedIndex];
    final segmentSize = 1 / _prizes.length;
    final segmentCenter = (selectedIndex + 0.5) * segmentSize;

    // Rotate enough full turns, then land with winning segment under the top pointer.
    final landingOffset = (1 - segmentCenter) % 1;
    final extraFullTurns = 6 + math.Random().nextInt(3);
    var targetTurns =
        _currentTurns.floorToDouble() + extraFullTurns + landingOffset;
    while (targetTurns <= _currentTurns) {
      targetTurns += 1;
    }

    _turnsAnimation = Tween<double>(
      begin: _currentTurns,
      end: targetTurns,
    ).animate(
      CurvedAnimation(
        parent: _spinController,
        curve: const Interval(0.0, 1.0, curve: _SpinCurve()),
      ),
    );

    setState(() {
      _isSpinning = true;
      _lastResult = selectedPrize;
    });

    try {
      // Deduct spin cost before spinning.
      await context.read<AuthProvider>().updateTotalPoints(points - _spinCost);

      await _spinController.forward(from: 0.0);
      _currentTurns = targetTurns;

      if (!mounted) return;
      setState(() => _isSpinning = false);

      // Play a short win burst after the wheel settles.
      await _celebrationController.forward(from: 0.0);
      if (!mounted) return;
      _showSpinResult();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSpinning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to spin. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showSpinResult() {
    if (_lastResult == null) return;

    context.read<NotificationProvider>().addRewardNotification(_lastResult!);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🎉 You Won!'),
        content: Text('You win $_lastResult.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    final points = user?.totalPoints ?? 0;
    final canSpin = points >= _spinCost;
    final eligibleSpins = points ~/ _spinCost;

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/rewards'),
      body: Stack(
        children: [
          Column(
            children: [
              // Blue Header
              Container(
                width: double.infinity,
                color: AppTheme.primaryBlue,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.person, color: Colors.white),
                      onPressed: () => context.push('/profile'),
                    ),
                    const Text(
                      'REWARDS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
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
                      onPressed: () {
                        if (!_showNotificationPanel) {
                          context.read<NotificationProvider>().markAllAsRead();
                        }
                        setState(() {
                          _showNotificationPanel = !_showNotificationPanel;
                        });
                      },
                    ),
                  ],
                ),
              ),
              // Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  // Error Banner (if insufficient points)
                  if (!canSpin)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEBEE),
                        border: Border.all(color: Colors.red.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error, color: Colors.red.shade700),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Not enough points! Need $_spinCost points.',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!canSpin) const SizedBox(height: 24),
                  // Stats Card
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade200),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.1),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _StatItem(
                              label: 'Total Points',
                              value: '$points',
                              icon: '💰',
                            ),
                            _StatItem(
                              label: 'Per Spinning Cost',
                              value: '$_spinCost',
                              icon: '🎡',
                            ),
                            _StatItem(
                              label: 'Eligible Spinning Count',
                              value: '$eligibleSpins',
                              icon: '🎯',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  // Spinning Wheel
                  Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer decorative gradient ring
                        AnimatedBuilder(
                          animation: _celebrationController,
                          builder: (context, _) {
                            final glow = _celebrationController.value;
                            return Container(
                              width: 316,
                              height: 316,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const SweepGradient(
                                  colors: [
                                    Color(0xFFFFD700),
                                    Color(0xFFFF6B35),
                                    Color(0xFFE040FB),
                                    Color(0xFF00E5FF),
                                    Color(0xFF69F0AE),
                                    Color(0xFFFFD700),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.amber.withValues(
                                      alpha: 0.18 + 0.42 * glow,
                                    ),
                                    blurRadius: 24 + 40 * glow,
                                    spreadRadius: 2 + 14 * glow,
                                  ),
                                  BoxShadow(
                                    color: Colors.purple.withValues(
                                      alpha: 0.10 + 0.25 * glow,
                                    ),
                                    blurRadius: 32 + 20 * glow,
                                    spreadRadius: 1 + 6 * glow,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        // White inner circle (creates the ring illusion)
                        Container(
                          width: 298,
                          height: 298,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                        AnimatedBuilder(
                          animation: _celebrationController,
                          builder: (context, child) => child!,
                          child: RotationTransition(
                            turns: _turnsAnimation,
                            child: CustomPaint(
                              painter: SpinWheelPainter(_prizes),
                              size: const Size(288, 288),
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: _WinBurst(
                            progress: _celebrationController,
                          ),
                        ),
                        Positioned(
                          top: -2,
                          child: SizedBox(
                            width: 44,
                            height: 48,
                            child: CustomPaint(
                              painter: PointerPainter(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _isSpinning
                        ? const SizedBox.shrink()
                        : (_lastResult != null
                            ? Text(
                                'Last win: $_lastResult',
                                key: const ValueKey('last_reward'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFF2E7D32),
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : const SizedBox.shrink()),
                  ),
                  const SizedBox(height: 40),
                  // Spin Button
                  ElevatedButton(
                    onPressed: _isSpinning ? null : _spin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      disabledBackgroundColor: Colors.grey.shade400,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Spin ($_spinCost pts)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
          // Notification Panel Overlay
          if (_showNotificationPanel)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () {
                  // Close panel when tapping outside
                  setState(() {
                    _showNotificationPanel = false;
                  });
                },
                child: Container(
                  color: Colors.black.withOpacity(0.3),
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
                      notifications:
                          context.watch<NotificationProvider>().notifications,
                      onClose: () {
                        setState(() {
                          _showNotificationPanel = false;
                        });
                      },
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final String icon;

  const _StatItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            icon,
            style: const TextStyle(fontSize: 28),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1565C0),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom spin curve: fast burst → settle with a tiny back-tick for realism.
class _SpinCurve extends Curve {
  const _SpinCurve();

  @override
  double transformInternal(double t) {
    // Fast acceleration then elastic slow-down
    if (t < 0.6) {
      // Accelerate phase
      return Curves.easeIn.transform(t / 0.6) * 0.75;
    } else {
      // Decelerate with slight elastic overshoot then snap
      final u = (t - 0.6) / 0.4;
      final base = Curves.easeOutCubic.transform(u);
      // Tiny wobble: add a damped sine
      final wobble = math.sin(u * math.pi * 2.5) * 0.012 * (1 - u);
      return 0.75 + (base + wobble) * 0.25;
    }
  }
}

class SpinWheelPainter extends CustomPainter {
  final List<String> prizes;

  SpinWheelPainter(this.prizes);

  // Rich gradient colour pairs [dark, light] for each segment
  static const List<List<Color>> _segmentColors = [
    [Color(0xFFE53935), Color(0xFFFF8A80)],   // red
    [Color(0xFFE65100), Color(0xFFFFAB40)],   // deep orange
    [Color(0xFFF9A825), Color(0xFFFFEE58)],   // amber
    [Color(0xFF2E7D32), Color(0xFF69F0AE)],   // green
    [Color(0xFF1565C0), Color(0xFF82B1FF)],   // blue
    [Color(0xFF4527A0), Color(0xFFB388FF)],   // deep purple
    [Color(0xFFAD1457), Color(0xFFF48FB1)],   // pink
    [Color(0xFF00838F), Color(0xFF84FFFF)],   // cyan
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final segCount = prizes.length;
    final sweepAngle = (2 * math.pi) / segCount;

    // ── Outer metallic rim ──────────────────────────────────────────────────
    final rimPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white, const Color(0xFFE0E0E0), const Color(0xFFBDBDBD)],
        stops: const [0.82, 0.93, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, rimPaint);

    // ── Segments ────────────────────────────────────────────────────────────
    for (int i = 0; i < segCount; i++) {
      final startAngle = (i * 2 * math.pi) / segCount - math.pi / 2;
      final colors = _segmentColors[i % _segmentColors.length];

      // Gradient fill
      final segPaint = Paint()
        ..shader = ui.Gradient.sweep(
          center,
          [colors[0], colors[1], colors[0]],
          [0.0, 0.5, 1.0],
          TileMode.clamp,
          startAngle,
          startAngle + sweepAngle,
        )
        ..style = PaintingStyle.fill;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 6),
        startAngle,
        sweepAngle,
        true,
        segPaint,
      );

      // White divider lines
      final dividerPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 6),
        startAngle,
        sweepAngle,
        true,
        dividerPaint,
      );

      // Decorative dot near rim
      final dotAngle = startAngle + sweepAngle / 2;
      final dotPos = Offset(
        center.dx + (radius - 18) * math.cos(dotAngle),
        center.dy + (radius - 18) * math.sin(dotAngle),
      );
      canvas.drawCircle(dotPos, 5,
          Paint()..color = Colors.white.withValues(alpha: 0.85));
      canvas.drawCircle(dotPos, 3, Paint()..color = colors[1]);

      // Prize text (rotated along segment centre)
      final textAngle = startAngle + sweepAngle / 2;
      final textRadius = (radius - 6) * 0.60;
      final textOffset = Offset(
        center.dx + textRadius * math.cos(textAngle),
        center.dy + textRadius * math.sin(textAngle),
      );

      canvas.save();
      canvas.translate(textOffset.dx, textOffset.dy);
      canvas.rotate(textAngle + math.pi / 2);

      // Shadow layer
      final shadowPainter = TextPainter(
        text: TextSpan(
          text: prizes[i],
          style: TextStyle(
            color: Colors.black.withValues(alpha: 0.35),
            fontWeight: FontWeight.w900,
            fontSize: 13,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      shadowPainter.paint(
        canvas,
        Offset(-shadowPainter.width / 2 + 1, -shadowPainter.height / 2 + 1),
      );

      // Main text
      final tp = TextPainter(
        text: TextSpan(
          text: prizes[i],
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));

      canvas.restore();
    }

    // ── Gloss overlay (top-half shine) ──────────────────────────────────────
    final glossPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -0.4),
        radius: 0.75,
        colors: [
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius - 6))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 6, glossPaint);

    // ── Center hub ──────────────────────────────────────────────────────────
    const hubRadius = 32.0;

    // Hub shadow
    canvas.drawCircle(
      center + const Offset(2, 2),
      hubRadius,
      Paint()..color = Colors.black.withValues(alpha: 0.3),
    );

    // Hub gradient
    final hubPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.4),
        radius: 0.9,
        colors: [const Color(0xFF42A5F5), const Color(0xFF0D47A1)],
      ).createShader(Rect.fromCircle(center: center, radius: hubRadius));
    canvas.drawCircle(center, hubRadius, hubPaint);

    // Hub rim
    canvas.drawCircle(
      center,
      hubRadius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    // Hub inner gloss
    canvas.drawCircle(
      center + const Offset(-6, -7),
      10,
      Paint()..color = Colors.white.withValues(alpha: 0.25),
    );

    // Hub emoji
    final hubText = TextPainter(
      text: const TextSpan(
        text: '🎡',
        style: TextStyle(fontSize: 26),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    hubText.paint(
      canvas,
      center - Offset(hubText.width / 2, hubText.height / 2),
    );
  }

  @override
  bool shouldRepaint(SpinWheelPainter oldDelegate) =>
      oldDelegate.prizes != prizes;
}

class PointerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    // Drop shadow
    final shadowPath = Path()
      ..moveTo(cx + 1.5, 2)
      ..lineTo(size.width - 2, size.height - 4)
      ..quadraticBezierTo(cx + 1.5, size.height + 4, cx + 1.5, size.height - 4)
      ..lineTo(2, size.height - 4)
      ..quadraticBezierTo(cx + 1.5, size.height + 4, cx + 1.5, 2)
      ..close();
    canvas.drawPath(
      shadowPath,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );

    // Main arrow body
    final arrowPath = Path()
      ..moveTo(cx, 0)
      ..lineTo(size.width - 2, size.height - 4)
      ..quadraticBezierTo(cx, size.height + 5, 2, size.height - 4)
      ..close();

    final arrowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [const Color(0xFFFF1744), const Color(0xFFB71C1C)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(arrowPath, arrowPaint);

    // Gloss highlight on left edge
    final glossPath = Path()
      ..moveTo(cx, 0)
      ..lineTo(cx - 4, size.height * 0.55)
      ..lineTo(cx, size.height * 0.5)
      ..close();
    canvas.drawPath(
      glossPath,
      Paint()..color = Colors.white.withValues(alpha: 0.30),
    );

    // White outline
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Tip dot
    canvas.drawCircle(
      Offset(cx, 4),
      3,
      Paint()..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(PointerPainter oldDelegate) => false;
}

class _WinBurst extends StatelessWidget {
  const _WinBurst({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final p = progress.value;
        if (p <= 0 || p >= 1) return const SizedBox.shrink();

        final opacity = (1 - p).clamp(0.0, 1.0);
        const angles = <double>[0, 45, 90, 135, 180, 225, 270, 315];

        return SizedBox(
          width: 320,
          height: 320,
          child: Stack(
            children: [
              for (final angle in angles)
                Positioned.fill(
                  child: Transform.rotate(
                    angle: angle * math.pi / 180,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Transform.translate(
                        offset: Offset(0, -(36 + 70 * p)),
                        child: Opacity(
                          opacity: opacity,
                          child: const Icon(
                            Icons.auto_awesome,
                            color: Colors.amber,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}