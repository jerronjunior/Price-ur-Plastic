import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';

enum _AdminTab { dash, users, bins, rewards, alerts }

/// Admin dashboard home screen with tabbed navigation.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _sentSearchController = TextEditingController();

  Map<String, int>? _stats;
  bool _isLoadingStats = true;
  bool _sendingMessage = false;

  _AdminTab _activeTab = _AdminTab.alerts;

  String _sendTarget = 'specific';
  String? _selectedUserId;
  String? _selectedUserName;

  DateTime? _fromDate;
  DateTime? _toDate;
  String _audienceFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadStats();
    _sentSearchController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _sentSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoadingStats = true);
    try {
      final stats = await _firestoreService.getAdminStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _isLoadingStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStats = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load stats: $e')),
      );
    }
  }

  Future<void> _sendAdminMessage() async {
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthProvider>();

    final message = _messageController.text.trim();
    if (message.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please enter a message.')),
      );
      return;
    }

    if (_sendTarget == 'specific' &&
        (_selectedUserId == null || _selectedUserId!.isEmpty)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please select a user.')),
      );
      return;
    }

    final adminId = auth.userId;
    if (adminId == null || adminId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Admin session not found. Please login again.'),
        ),
      );
      return;
    }

    setState(() => _sendingMessage = true);
    try {
      await _firestoreService.sendAdminMessage(
        adminId: adminId,
        message: message,
        targetUserId: _sendTarget == 'specific' ? _selectedUserId : null,
        targetUserName: _sendTarget == 'specific' ? _selectedUserName : null,
      );

      if (!mounted) return;
      setState(() {
        _messageController.clear();
        if (_sendTarget == 'specific') {
          _selectedUserId = null;
          _selectedUserName = null;
        }
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Notification sent successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to send notification: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _sendingMessage = false);
      }
    }
  }

  Future<void> _deleteSentMessage(String id) async {
    await _firestoreService.deleteSentAdminMessage(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sent notification deleted.')),
    );
  }

  Future<void> _clearAllSentMessages() async {
    final adminId = context.read<AuthProvider>().userId;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear sent notifications?'),
        content: const Text(
          'This will remove all your sent message history from this list.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear All')),
        ],
      ),
    );

    if (confirmed != true) return;

    final count = await _firestoreService.clearSentAdminMessages(adminId: adminId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared $count sent notification(s).')),
    );
  }

  Future<void> _pickDate({required bool from}) async {
    final initial = from ? (_fromDate ?? DateTime.now()) : (_toDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _fromDate = DateTime(picked.year, picked.month, picked.day);
      } else {
        _toDate = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      }
    });
  }

  DateTime? _extractCreatedAt(Map<String, dynamic> item) {
    final raw = item['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  bool _isInDateRange(Map<String, dynamic> item) {
    if (_fromDate == null && _toDate == null) return true;
    final createdAt = _extractCreatedAt(item);
    if (createdAt == null) return true;
    if (_fromDate != null && createdAt.isBefore(_fromDate!)) return false;
    if (_toDate != null && createdAt.isAfter(_toDate!)) return false;
    return true;
  }

  List<Map<String, dynamic>> _applySentFilters(List<Map<String, dynamic>> sent) {
    final query = _sentSearchController.text.trim().toLowerCase();

    return sent.where((item) {
      if (!_isInDateRange(item)) return false;

      final audience = (item['audience'] ?? '').toString();
      if (_audienceFilter != 'all' && audience != _audienceFilter) return false;

      if (query.isEmpty) return true;
      final subtitle = (item['subtitle'] ?? '').toString().toLowerCase();
      final time = (item['time'] ?? '').toString().toLowerCase();
      return subtitle.contains(query) || audience.toLowerCase().contains(query) || time.contains(query);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9EDF2),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFFE9EDF2),
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Color(0xFF0B7A2A)),
          onPressed: () {},
        ),
        title: const Text(
          'RecycleScan Admin',
          style: TextStyle(
            color: Color(0xFF0B7A2A),
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.power_settings_new, color: Color(0xFFC65151)),
              onPressed: () async {
                final router = GoRouter.of(context);
                await context.read<AuthProvider>().logout();
                if (!mounted) return;
                router.go('/login');
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadStats,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  child: _buildActiveTabBody(),
                ),
              ),
            ),
            _buildBottomTabBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveTabBody() {
    switch (_activeTab) {
      case _AdminTab.dash:
        return Column(
          children: [
            _buildStatsSection(),
            const SizedBox(height: 14),
            _buildActionTile(
              icon: Icons.people_alt_outlined,
              title: 'View Users',
              subtitle: 'Open user points and bottles overview',
              onTap: () => setState(() => _activeTab = _AdminTab.users),
            ),
            const SizedBox(height: 10),
            _buildActionTile(
              icon: Icons.notifications_active_outlined,
              title: 'Open Alerts',
              subtitle: 'Send and review admin notifications',
              onTap: () => setState(() => _activeTab = _AdminTab.alerts),
            ),
          ],
        );
      case _AdminTab.users:
        return _buildUsersSection();
      case _AdminTab.bins:
        return _buildRouteSection(
          title: 'Bins',
          description: 'Manage recycling bins and locations.',
          buttonText: 'Open Bin Manager',
          onPressed: () => context.push('/admin/bins'),
        );
      case _AdminTab.rewards:
        return _buildRouteSection(
          title: 'Rewards',
          description: 'Configure reward tiers and points.',
          buttonText: 'Open Rewards Manager',
          onPressed: () => context.push('/admin/rewards'),
        );
      case _AdminTab.alerts:
        return _buildAlertsSection();
    }
  }

  Widget _buildBottomTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _tabItem(icon: Icons.dashboard_customize_outlined, label: 'Dash', tab: _AdminTab.dash),
          _tabItem(icon: Icons.group_outlined, label: 'Users', tab: _AdminTab.users),
          _tabItem(icon: Icons.delete_outline, label: 'Bins', tab: _AdminTab.bins),
          _tabItem(icon: Icons.card_giftcard_outlined, label: 'Rewards', tab: _AdminTab.rewards),
          _tabItem(icon: Icons.notifications_active_outlined, label: 'Alerts', tab: _AdminTab.alerts),
        ],
      ),
    );
  }

  Widget _tabItem({
    required IconData icon,
    required String label,
    required _AdminTab tab,
  }) {
    final selected = _activeTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeTab = tab),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFDDEBDD) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: selected ? const Color(0xFF1F6F2D) : Colors.grey[600]),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? const Color(0xFF1F6F2D) : Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsSection() {
    if (_isLoadingStats) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_stats == null) {
      return _panel(
        child: const Padding(
          padding: EdgeInsets.all(18),
          child: Text('No stats available'),
        ),
      );
    }

    return Column(
      children: [
        _panel(
          child: Row(
            children: [
              Expanded(
                child: _metricCard(
                  title: 'Users',
                  value: '${_stats!['totalUsers'] ?? 0}',
                  icon: Icons.people,
                  color: AppTheme.primaryBlue,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _metricCard(
                  title: 'Bins',
                  value: '${_stats!['totalBins'] ?? 0}',
                  icon: Icons.delete_outline,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _panel(
          child: _metricCard(
            title: 'Bottles Recycled',
            value: '${_stats!['totalBottlesRecycled'] ?? 0}',
            icon: Icons.recycling,
            color: AppTheme.accent,
            compact: false,
          ),
        ),
      ],
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    bool compact = true,
  }) {
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 10),
      child: Column(
        children: [
          Icon(icon, color: color, size: compact ? 28 : 32),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 24 : 30,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return _panel(
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF1F6F2D)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Widget _buildRouteSection({
    required String title,
    required String description,
    required String buttonText,
    required VoidCallback onPressed,
  }) {
    return _panel(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(description, style: TextStyle(color: Colors.grey[700])),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.open_in_new),
                label: Text(buttonText),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertsSection() {
    final adminId = context.read<AuthProvider>().userId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panel(child: _buildSendPanel()),
        const SizedBox(height: 14),
        _panel(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _firestoreService.sentAdminMessagesStream(adminId: adminId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                if (snapshot.hasError) {
                  return Text('Failed to load sent notifications: ${snapshot.error}');
                }

                final sentAll = snapshot.data ?? const <Map<String, dynamic>>[];
                final audiences = sentAll
                    .map((e) => (e['audience'] ?? '').toString())
                    .where((e) => e.isNotEmpty)
                    .toSet()
                    .toList()
                  ..sort();

                final sent = _applySentFilters(sentAll);

                if (_audienceFilter != 'all' &&
                    !audiences.contains(_audienceFilter)) {
                  _audienceFilter = 'all';
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Sent Notifications',
                            style: TextStyle(fontSize: 31, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (sentAll.isNotEmpty)
                          TextButton.icon(
                            onPressed: _clearAllSentMessages,
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('Clear All'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _sentSearchController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Search sent messages',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _audienceFilter,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'Filter by user',
                            ),
                            items: [
                              const DropdownMenuItem(value: 'all', child: Text('All users')),
                              ...audiences.map(
                                (a) => DropdownMenuItem(value: a, child: Text(a)),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _audienceFilter = v);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickDate(from: true),
                            icon: const Icon(Icons.date_range),
                            label: Text(
                              _fromDate == null
                                  ? 'From date'
                                  : '${_fromDate!.day}/${_fromDate!.month}/${_fromDate!.year}',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickDate(from: false),
                            icon: const Icon(Icons.event),
                            label: Text(
                              _toDate == null
                                  ? 'To date'
                                  : '${_toDate!.day}/${_toDate!.month}/${_toDate!.year}',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Clear date filters',
                          onPressed: () => setState(() {
                            _fromDate = null;
                            _toDate = null;
                          }),
                          icon: const Icon(Icons.clear),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (sent.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No notifications sent yet',
                            style: TextStyle(fontSize: 18, color: Colors.black54),
                          ),
                        ),
                      )
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: sent.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = sent[index];
                          final subtitle = (item['subtitle'] ?? '').toString();
                          final time = (item['time'] ?? '').toString();
                          final audience = (item['audience'] ?? 'Unknown').toString();
                          final recipients = (item['recipients'] ?? 0).toString();
                          final id = (item['id'] ?? '').toString();

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            title: Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('To: $audience • Recipients: $recipients\n$time'),
                            leading: const Icon(Icons.mark_email_read_outlined),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              onPressed: id.isEmpty ? null : () => _deleteSentMessage(id),
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendPanel() {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('SEND TO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _sendTarget,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
            items: const [
              DropdownMenuItem(value: 'specific', child: Text('Specific user')),
              DropdownMenuItem(value: 'all', child: Text('All users')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _sendTarget = value;
                if (value != 'specific') {
                  _selectedUserId = null;
                  _selectedUserName = null;
                }
              });
            },
          ),
          const SizedBox(height: 12),
          if (_sendTarget == 'specific') ...[
            const Text('SELECT USER', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            StreamBuilder<List<UserModel>>(
              stream: _firestoreService.allUsersStream(),
              builder: (context, snapshot) {
                final users = snapshot.data ?? const <UserModel>[];
                return DropdownButtonFormField<String>(
                  value: _selectedUserId,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                  hint: const Text('Choose user'),
                  items: users
                      .map((user) => DropdownMenuItem<String>(
                            value: user.userId,
                            child: Text(user.name.isNotEmpty ? user.name : user.email),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    final user = users.firstWhere(
                      (u) => u.userId == value,
                      orElse: () => const UserModel(userId: '', name: '', email: ''),
                    );
                    setState(() {
                      _selectedUserId = value;
                      _selectedUserName = user.name.isNotEmpty ? user.name : user.email;
                    });
                  },
                );
              },
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _messageController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Message',
              hintText: 'Type notification message',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _sendingMessage ? null : _sendAdminMessage,
              icon: _sendingMessage
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(_sendingMessage ? 'Sending...' : 'Send Notification'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsersSection() {
    return _panel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'User Points And Bottles',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<UserModel>>(
              stream: _firestoreService.allUsersStream(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Failed to load users: ${snapshot.error}'),
                  );
                }

                final users = snapshot.data ?? const <UserModel>[];
                if (users.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No users available'),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: users.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final user = users[index];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppTheme.primaryBlue.withValues(alpha: 0.12),
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
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
