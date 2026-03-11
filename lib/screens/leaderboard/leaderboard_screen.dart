import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../widgets/bottom_nav_bar.dart';
import '../../widgets/notification_panel.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  bool _showNotificationPanel = false;
  late AnimationController _animCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        duration: const Duration(milliseconds: 600), vsync: this)
      ..forward();
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final firestore = context.read<FirestoreService>();
    final currentUserId = context.read<AuthProvider>().userId;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      bottomNavigationBar: const AppBottomNavBar(currentRoute: '/leaderboard'),
      body: Stack(
        children: [
          Column(
            children: [
              // ── Header ────────────────────────────────────────────────
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.person, color: Colors.white),
                            onPressed: () => context.push('/profile'),
                          ),
                          const Expanded(
                            child: Center(
                              child: Text(
                                'LEADERBOARD',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.notifications,
                                color: Colors.white),
                            onPressed: () => setState(() =>
                                _showNotificationPanel =
                                    !_showNotificationPanel),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── Live leaderboard ───────────────────────────────────────
              Expanded(
                child: StreamBuilder<List<UserModel>>(
                  // Use unlimited stream — we need real ranks for everyone
                  stream: firestore.leaderboardStreamAll(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(color: Color(0xFF1565C0)),
                            SizedBox(height: 12),
                            Text('Loading players...',
                                style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      );
                    }

                    if (snapshot.hasError) {
                      return _ErrorState(
                          message: snapshot.error.toString());
                    }

                    // snapshot.data is null until first emission
                    if (!snapshot.hasData) {
                      return const Center(
                        child: Text('No data received yet...',
                            style: TextStyle(color: Colors.grey)),
                      );
                    }

                    final users = snapshot.data!;

                    if (users.isEmpty) {
                      return const _EmptyState();
                    }

                    // Find current user's rank
                    final myIndex = currentUserId != null
                        ? users.indexWhere((u) => u.userId == currentUserId)
                        : -1;
                    final myRank = myIndex >= 0 ? myIndex + 1 : null;

                    return FadeTransition(
                      opacity: _fadeAnim,
                      child: CustomScrollView(
                        slivers: [
                          // ── Top 3 Podium ─────────────────────────────
                          if (users.length >= 3)
                            SliverToBoxAdapter(
                              child: _Podium(
                                users: users.take(3).toList(),
                                currentUserId: currentUserId,
                              ),
                            ),

                          // ── "Your rank" banner if outside top 3 ──────
                          if (myRank != null && myRank > 3)
                            SliverToBoxAdapter(
                              child: _MyRankBanner(
                                rank: myRank,
                                user: users[myIndex],
                              ),
                            ),

                          // ── Section header ───────────────────────────
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                              child: Row(
                                children: [
                                  const Text('🏆 ',
                                      style: TextStyle(fontSize: 18)),
                                  Text(
                                    'All Rankings',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${users.length} players',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ── Full ranked list ─────────────────────────
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final user = users[index];
                                  final rank = index + 1;
                                  final isMe = user.userId == currentUserId;
                                  return _RankRow(
                                    rank: rank,
                                    user: user,
                                    isMe: isMe,
                                    animDelay:
                                        Duration(milliseconds: 40 * index),
                                  );
                                },
                                childCount: users.length,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),

          // ── Notification panel ─────────────────────────────────────────
          if (_showNotificationPanel)
            Positioned.fill(
              child: GestureDetector(
                onTap: () =>
                    setState(() => _showNotificationPanel = false),
                child: Container(
                  color: Colors.black38,
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () {},
                    child: NotificationPanel(
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Top 3 Podium
// ─────────────────────────────────────────────────────────────────────────────
class _Podium extends StatelessWidget {
  const _Podium({required this.users, required this.currentUserId});
  final List<UserModel> users;
  final String? currentUserId;

  @override
  Widget build(BuildContext context) {
    // Podium order: 2nd (left) | 1st (center, tallest) | 3rd (right)
    final order = [
      (index: 1, height: 90.0,  color: const Color(0xFFB0BEC5), crown: '🥈'),
      (index: 0, height: 120.0, color: const Color(0xFFFFA000), crown: '🏆'),
      (index: 2, height: 70.0,  color: const Color(0xFFBF8A5E), crown: '🥉'),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1565C0), Color(0xFF1976D2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1565C0).withOpacity(0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: order.map((item) {
          final user = users[item.index];
          final isMe = user.userId == currentUserId;
          final rank = item.index + 1;
          return _PodiumSlot(
            user: user,
            rank: rank,
            podiumHeight: item.height,
            color: item.color,
            crown: item.crown,
            isMe: isMe,
          );
        }).toList(),
      ),
    );
  }
}

class _PodiumSlot extends StatelessWidget {
  const _PodiumSlot({
    required this.user,
    required this.rank,
    required this.podiumHeight,
    required this.color,
    required this.crown,
    required this.isMe,
  });

  final UserModel user;
  final int rank;
  final double podiumHeight;
  final Color color;
  final String crown;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Crown
        Text(crown, style: const TextStyle(fontSize: 22)),
        const SizedBox(height: 6),

        // Avatar
        Container(
          width: rank == 1 ? 64 : 52,
          height: rank == 1 ? 64 : 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.15),
            border: Border.all(
              color: isMe ? Colors.yellow : Colors.white.withOpacity(0.5),
              width: isMe ? 3 : 1.5,
            ),
          ),
          child: Center(
            child: Text(
              user.name.isNotEmpty
                  ? user.name[0].toUpperCase()
                  : '?',
              style: TextStyle(
                color: Colors.white,
                fontSize: rank == 1 ? 26 : 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Name
        SizedBox(
          width: 90,
          child: Text(
            isMe ? '${user.name} (You)' : user.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // Points
        Text(
          '${user.totalPoints} pts',
          style: TextStyle(
            color: Colors.white.withOpacity(0.85),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),

        // Podium block
        Container(
          width: rank == 1 ? 80 : 68,
          height: podiumHeight,
          decoration: BoxDecoration(
            color: color.withOpacity(0.85),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Center(
            child: Text(
              '#$rank',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "Your Rank" sticky banner (shown when current user is outside top 3)
// ─────────────────────────────────────────────────────────────────────────────
class _MyRankBanner extends StatelessWidget {
  const _MyRankBanner({required this.rank, required this.user});
  final int rank;
  final UserModel user;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1565C0).withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1565C0), width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.person_pin,
              color: Color(0xFF1565C0), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Your Ranking',
                    style: TextStyle(
                        color: Color(0xFF1565C0),
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                Text(user.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('#$rank',
                  style: const TextStyle(
                      color: Color(0xFF1565C0),
                      fontWeight: FontWeight.bold,
                      fontSize: 20)),
              Text('${user.totalPoints} pts',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual rank row
// ─────────────────────────────────────────────────────────────────────────────
class _RankRow extends StatefulWidget {
  const _RankRow({
    required this.rank,
    required this.user,
    required this.isMe,
    required this.animDelay,
  });
  final int rank;
  final UserModel user;
  final bool isMe;
  final Duration animDelay;

  @override
  State<_RankRow> createState() => _RankRowState();
}

class _RankRowState extends State<_RankRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 350), vsync: this);
    _slide = Tween<Offset>(
            begin: const Offset(0.3, 0), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

    Future.delayed(widget.animDelay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rank = widget.rank;
    final user = widget.user;
    final isMe = widget.isMe;

    // Rank badge color
    Color badgeColor;
    Color badgeText;
    if (rank == 1) {
      badgeColor = const Color(0xFFFFA000);
      badgeText = Colors.white;
    } else if (rank == 2) {
      badgeColor = const Color(0xFFB0BEC5);
      badgeText = Colors.white;
    } else if (rank == 3) {
      badgeColor = const Color(0xFFBF8A5E);
      badgeText = Colors.white;
    } else {
      badgeColor = Colors.grey.shade200;
      badgeText = Colors.grey.shade700;
    }

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: isMe
                ? const Color(0xFF1565C0).withOpacity(0.06)
                : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: isMe
                ? Border.all(color: const Color(0xFF1565C0), width: 1.5)
                : Border.all(color: Colors.grey.shade100),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Rank badge
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: badgeColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: rank <= 3
                        ? Text(
                            rank == 1
                                ? '🏆'
                                : rank == 2
                                    ? '🥈'
                                    : '🥉',
                            style: const TextStyle(fontSize: 16),
                          )
                        : Text(
                            '$rank',
                            style: TextStyle(
                              color: badgeText,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),

                // Avatar circle
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isMe
                        ? const Color(0xFF1565C0).withOpacity(0.15)
                        : Colors.grey.shade100,
                  ),
                  child: Center(
                    child: Text(
                      user.name.isNotEmpty
                          ? user.name[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: isMe
                            ? const Color(0xFF1565C0)
                            : Colors.grey.shade700,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Name + bottles
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              user.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: isMe
                                    ? const Color(0xFF1565C0)
                                    : Colors.black87,
                              ),
                            ),
                          ),
                          if (isMe) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1565C0),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('You',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '🍾 ${user.totalBottles} bottles recycled',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),

                // Points
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${user.totalPoints}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: rank <= 3
                            ? badgeColor
                            : isMe
                                ? const Color(0xFF1565C0)
                                : Colors.black87,
                      ),
                    ),
                    Text('pts',
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade400)),
                  ],
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
// Empty / Error states
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.leaderboard, size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text('No players yet',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          Text('Be the first to recycle a bottle!',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text('Could not load leaderboard',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            // Show full error in a scrollable box so nothing is cut off
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: SelectableText(
                message,
                style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade800,
                    fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'See terminal logs for the full error details.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}