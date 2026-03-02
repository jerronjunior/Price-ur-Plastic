import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';

/// Landing screen for scan & recycle feature.
class ScanLandingScreen extends StatefulWidget {
  const ScanLandingScreen({super.key});

  @override
  State<ScanLandingScreen> createState() => _ScanLandingScreenState();
}

class _ScanLandingScreenState extends State<ScanLandingScreen> {
  bool _showNotificationPanel = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
        children: [
          // Blue Header
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
                    icon: const Icon(Icons.person, color: Colors.white),
                    onPressed: () => context.push('/profile'),
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
          ),
          // Body
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 40),
                  // Camera Icon
                  Text(
                    '📷',
                    style: Theme.of(context).textTheme.displayLarge,
                  ),
                  const SizedBox(height: 32),
                  // Title
                  Text(
                    'Scan & Recycle',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: const Color(0xFF1565C0),
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  // Description
                  Text(
                    'Scan a bottle barcode or detect a recycling bin to earn points',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  // Scan Bottle Barcode Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => context.push('/scan-flow'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Scan Bottle Barcode',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Detect Recycling Bin Button (disabled)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Bin detection coming soon!'),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Detect Recycling Bin',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  // Scan result
                  Text(
                    'Scan result : Unknown',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey.shade600,
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
      bottomNavigationBar: AppBottomNavBar(currentRoute: '/scan'),
    );
  }
}
