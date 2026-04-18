import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../models/user_model.dart';
import '../../providers/notification_provider.dart';
import '../../services/firestore_service.dart';
import '../../core/theme.dart';
import '../../widgets/notification_panel.dart';

/// Admin dashboard home screen with stats and navigation.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  Map<String, int>? _stats;
  bool _isLoading = true;
  bool _showNotificationPanel = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    try {
      final stats = await _firestoreService.getAdminStats();
      setState(() {
        _stats = stats;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load stats: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = context.watch<NotificationProvider>().hasUnread;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications),
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
              setState(() => _showNotificationPanel = !_showNotificationPanel);
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStats,
          ),
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _loadStats,
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildStatsSection(),
                        const SizedBox(height: 24),
                        _buildAdminActionsSection(),
                        const SizedBox(height: 24),
                        _buildUsersSection(),
                      ],
                    ),
                  ),
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
                      onClose: () =>
                          setState(() => _showNotificationPanel = false),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatsSection() {
    if (_stats == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No stats available'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'System Statistics',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                'Total Users',
                _stats!['totalUsers']!,
                Icons.people,
                AppTheme.primaryBlue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                'Total Bins',
                _stats!['totalBins']!,
                Icons.delete_outline,
                AppTheme.primaryGreen,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildStatCard(
          'Total Bottles Recycled',
          _stats!['totalBottlesRecycled']!,
          Icons.recycling,
          AppTheme.accent,
          isFullWidth: true,
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String label,
    int value,
    IconData icon,
    Color color, {
    bool isFullWidth = false,
  }) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(height: 8),
            Text(
              value.toString(),
              style: TextStyle(
                fontSize: isFullWidth ? 32 : 28,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminActionsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Admin Actions',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        _buildActionCard(
          'Manage Bins',
          'Add, edit, or remove recycling bins',
          Icons.qr_code_scanner,
          AppTheme.primaryGreen,
          () => context.push('/admin/bins'),
        ),
        const SizedBox(height: 12),
        _buildActionCard(
          'Manage Rewards',
          'Configure reward points and tiers',
          Icons.stars,
          AppTheme.primaryBlue,
          () => context.push('/admin/rewards'),
        ),
      ],
    );
  }

  Widget _buildActionCard(
    String title,
    String description,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 32, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUsersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'User Points And Bottles',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        StreamBuilder<List<UserModel>>(
          stream: _firestoreService.allUsersStream(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Failed to load users: ${snapshot.error}'),
                ),
              );
            }
            final users = snapshot.data ?? const <UserModel>[];
            if (users.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No users available'),
                ),
              );
            }
            return Column(
              children: users.map((user) {
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primaryBlue.withOpacity(0.12),
                      child: Text(
                        user.name.isNotEmpty ? user.name[0].toUpperCase() : 'U',
                        style: const TextStyle(color: AppTheme.primaryBlue),
                      ),
                    ),
                    title: Text(user.name),
                    subtitle: Text(user.email),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${user.totalPoints} pts'),
                        Text('${user.totalBottles} bottles'),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
