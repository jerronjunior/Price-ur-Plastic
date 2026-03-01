import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:math' as math;
import '../../providers/auth_provider.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';

class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _spinController;
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

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      duration: const Duration(seconds: 5),
      vsync: this,
    );
    _spinController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _isSpinning = false);
        _showSpinResult();
      }
    });
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  void _spin() {
    final user = context.read<AuthProvider>().user;
    final points = user?.totalPoints ?? 0;

    if (points < _spinCost) return;

    setState(() => _isSpinning = true);

    // Random spin with random offset for landing position
    final randomOffset = math.Random().nextDouble();

    _spinController.forward(from: 0.0).then((_) {
      final selectedIndex = (randomOffset * _prizes.length).toInt() % _prizes.length;
      _lastResult = _prizes[selectedIndex];

      // Deduct points from user
      context.read<AuthProvider>().updateTotalPoints(points - _spinCost);
    });
  }

  void _showSpinResult() {
    if (_lastResult == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🎉 You Won!'),
        content: Text('You got: $_lastResult'),
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
    final points = user?.totalPoints ?? 0;
    final canSpin = points >= _spinCost;
    final eligibleSpins = points ~/ _spinCost;

    return Scaffold(
      bottomNavigationBar: AppBottomNavBar(currentRoute: '/rewards'),
      body: Stack(
        children: [
          Column(
            children: [
              // Blue Header
              Container(
                width: double.infinity,
                color: const Color(0xFF1565C0),
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
                      icon: const Icon(Icons.notifications, color: Colors.white),
                      onPressed: () {
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
                    child: RotationTransition(
                      turns: Tween(begin: 0.0, end: 10.0).animate(_spinController),
                      child: CustomPaint(
                        painter: SpinWheelPainter(_prizes),
                        size: const Size(280, 280),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Pointer at top
                  Center(
                    child: CustomPaint(
                      painter: PointerPainter(),
                      size: const Size(40, 40),
                    ),
                  ),
                  const SizedBox(height: 40),
                  // Spin Button
                  ElevatedButton(
                    onPressed: _isSpinning || !canSpin ? null : _spin,
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

class SpinWheelPainter extends CustomPainter {
  final List<String> prizes;

  SpinWheelPainter(this.prizes);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final paint = Paint();
    final colors = [
      Colors.red.shade400,
      Colors.orange.shade400,
      Colors.yellow.shade600,
      Colors.green.shade400,
      Colors.blue.shade400,
      Colors.indigo.shade400,
      Colors.purple.shade400,
      Colors.pink.shade400,
    ];

    final strokePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    // Draw segments
    for (int i = 0; i < prizes.length; i++) {
      final startAngle = (i * 2 * math.pi) / prizes.length - math.pi / 2;
      final sweepAngle = (2 * math.pi) / prizes.length;

      paint.color = colors[i % colors.length];

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );

      // Draw segment border
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        strokePaint,
      );

      // Draw prize text
      final textAngle = startAngle + sweepAngle / 2;
      final textRadius = radius * 0.7;
      final textOffset = Offset(
        center.dx + textRadius * math.cos(textAngle),
        center.dy + textRadius * math.sin(textAngle),
      );

      final textPainter = TextPainter(
        text: TextSpan(
          text: prizes[i],
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        textOffset - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }

    // Draw center circle
    final centerCirclePaint = Paint()
      ..color = const Color(0xFF1565C0)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 30, centerCirclePaint);

    // Draw center circle border
    canvas.drawCircle(center, 30, strokePaint);

    // Draw center icon/text
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '🎡',
        style: TextStyle(fontSize: 24),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(SpinWheelPainter oldDelegate) {
    return oldDelegate.prizes != prizes;
  }
}

class PointerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(size.width / 2, 0);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(PointerPainter oldDelegate) => false;
}
