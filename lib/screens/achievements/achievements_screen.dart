import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/achievements/achievement_definitions.dart';
import '../../services/achievements/achievement_service.dart';
import '../../services/achievements/friend_service.dart';
import '../../widgets/achievement_badge.dart';

const _green = Color(0xFF2E7D32);
const _darkGreen = Color(0xFF1B5E20);
const _background = Color(0xFFF1F8E9);

enum _Filter { all, unlocked, locked }

class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});
  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  Map<String, int> _stats = {};
  Set<String> _unlocked = {};
  _Filter _filter = _Filter.all;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await FriendService().syncFriendsCount();
      final progress = await AchievementService().loadProgress();
      if (!mounted) return;
      setState(() {
        _stats = progress?.stats ?? {};
        _unlocked = progress?.unlocked ?? {};
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = kAchievements.where((a) => _unlocked.contains(a.id)).fold<int>(0, (sum, a) => sum + a.points);
    final stars = kAchievements.where((a) => _unlocked.contains(a.id)).fold<int>(0, (sum, a) => sum + a.tier);
    return Scaffold(
      backgroundColor: _background,
      body: Column(children: [
        _Header(unlocked: _unlocked.length, points: points, stars: stars, onBack: () => context.canPop() ? context.pop() : context.go('/rewards')),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : _error
                ? _ErrorView(onRetry: () { setState(() => _loading = true); _load(); })
                : RefreshIndicator(
                    color: _green,
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 28), physics: const AlwaysScrollableScrollPhysics(), children: [
                      _FilterBar(value: _filter, onChanged: (value) => setState(() => _filter = value)),
                      const SizedBox(height: 14),
                      ..._sections(),
                    ]),
                  )),
      ]),
    );
  }

  List<Widget> _sections() {
    final sections = <Widget>[];
    for (final entry in kAchievementsByCategory.entries) {
      final visible = entry.value.where((a) {
        final unlocked = _unlocked.contains(a.id);
        return _filter == _Filter.all || (_filter == _Filter.unlocked && unlocked) || (_filter == _Filter.locked && !unlocked);
      }).toList();
      if (visible.isEmpty) continue;
      sections.add(_CategoryCard(category: entry.key, all: entry.value, visible: visible, unlocked: _unlocked, count: _stats[entry.key.statField] ?? 0, onTap: _showDetail));
      sections.add(const SizedBox(height: 14));
    }
    if (sections.isEmpty) {
      sections.add(Padding(padding: const EdgeInsets.only(top: 60), child: Text(_filter == _Filter.unlocked ? 'No achievements unlocked yet.\nRecycle a bottle to get your first!' : 'You have unlocked everything. Amazing!', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600))));
    }
    return sections;
  }

  void _showDetail(AchievementDef achievement) {
    final unlocked = _unlocked.contains(achievement.id);
    final count = _stats[achievement.category.statField] ?? 0;
    final progress = (count / achievement.threshold).clamp(0.0, 1.0);
    showModalBottomSheet<void>(context: context, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))), builder: (_) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(24, 18, 24, 24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      AchievementBadge(achievement: achievement, unlocked: unlocked, size: 96),
      const SizedBox(height: 14),
      Text(achievement.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _darkGreen)),
      const SizedBox(height: 4),
      Text(achievement.description, style: TextStyle(color: Colors.grey.shade600)),
      const SizedBox(height: 10),
      _Stars(count: achievement.tier, active: unlocked),
      const SizedBox(height: 16),
      if (unlocked) Text('Unlocked  ·  +${achievement.points} points earned', style: const TextStyle(color: _green, fontWeight: FontWeight.bold)) else ...[
        LinearProgressIndicator(value: progress, minHeight: 8, color: _green, backgroundColor: Colors.grey.shade200),
        const SizedBox(height: 8), Text('$count / ${achievement.threshold}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8), Text('Reward: +${achievement.points} points', style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
      ],
    ]))));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.unlocked, required this.points, required this.stars, required this.onBack});
  final int unlocked, points, stars;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) {
    return Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(8, 8, 8, 22), decoration: const BoxDecoration(gradient: LinearGradient(colors: [_green, _darkGreen]), borderRadius: BorderRadius.vertical(bottom: Radius.circular(28))), child: SafeArea(bottom: false, child: Column(children: [
      Row(children: [IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back, color: Colors.white)), const Expanded(child: Center(child: Text('ACHIEVEMENTS', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)))), const SizedBox(width: 48)]),
      const SizedBox(height: 14),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_HeaderStat(icon: Icons.emoji_events, value: '$unlocked/${kAchievements.length}', label: 'Unlocked'), _HeaderStat(icon: Icons.star, value: '$stars', label: 'Stars'), _HeaderStat(icon: Icons.bolt, value: '+$points', label: 'Points')]),
    ])));
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({required this.icon, required this.value, required this.label});
  final IconData icon; final String value, label;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12), decoration: BoxDecoration(color: Colors.white.withValues(alpha: .14), borderRadius: BorderRadius.circular(14)), child: Column(children: [Icon(icon, color: const Color(0xFFFFD54F), size: 18), const SizedBox(height: 2), Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11))]));
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});
  final _Filter value; final ValueChanged<_Filter> onChanged;
  @override
  Widget build(BuildContext context) => Row(children: _Filter.values.map((filter) => Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(filter.name[0].toUpperCase() + filter.name.substring(1)), selected: value == filter, onSelected: (_) => onChanged(filter), selectedColor: _green, showCheckmark: false, labelStyle: TextStyle(color: value == filter ? Colors.white : Colors.grey.shade700, fontWeight: FontWeight.w600)))).toList());
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.all, required this.visible, required this.unlocked, required this.count, required this.onTap});
  final AchievementCategory category; final List<AchievementDef> all, visible; final Set<String> unlocked; final int count; final ValueChanged<AchievementDef> onTap;
  @override
  Widget build(BuildContext context) {
    final done = all.where((a) => unlocked.contains(a.id)).length;
    final next = all.firstWhere((a) => !unlocked.contains(a.id), orElse: () => all.last);
    final complete = done == all.length;
    final progress = complete ? 1.0 : (count / next.threshold).clamp(0.0, 1.0);
    return Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(color: _green.withValues(alpha: .08), blurRadius: 12, offset: const Offset(0, 4))]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Text(category.emoji, style: const TextStyle(fontSize: 20)), const SizedBox(width: 10), Expanded(child: Text(category.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _darkGreen))), Text('$done/${all.length}', style: TextStyle(color: Colors.grey.shade600))]),
      const SizedBox(height: 12), LinearProgressIndicator(value: progress, minHeight: 7, color: complete ? Colors.orange : Colors.green, backgroundColor: Colors.grey.shade200),
      const SizedBox(height: 6), Text(complete ? 'All tiers complete' : 'Next: ${next.title} · $count / ${next.threshold}', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
      const SizedBox(height: 12), Row(crossAxisAlignment: CrossAxisAlignment.start, children: all.map((a) => Expanded(child: visible.contains(a) ? _Tile(achievement: a, unlocked: unlocked.contains(a.id), onTap: () => onTap(a)) : const SizedBox.shrink())).toList()),
    ]));
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.achievement, required this.unlocked, required this.onTap});
  final AchievementDef achievement; final bool unlocked; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4), child: Column(children: [AchievementBadge(achievement: achievement, unlocked: unlocked, size: 62), const SizedBox(height: 8), _Stars(count: achievement.tier, active: unlocked, size: 12), const SizedBox(height: 4), Text(achievement.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: unlocked ? _darkGreen : Colors.grey.shade500)), const SizedBox(height: 4), Text('+${achievement.points} pts', style: TextStyle(fontSize: 10.5, color: unlocked ? _green : Colors.grey.shade500))])));
}

class _Stars extends StatelessWidget {
  const _Stars({required this.count, required this.active, this.size = 18});
  final int count; final bool active; final double size;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: List.generate(3, (i) => Icon(i < count ? Icons.star : Icons.star_border, size: size, color: i < count && active ? Colors.amber : Colors.grey.shade300)));
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.cloud_off, size: 48, color: Colors.grey.shade400), const SizedBox(height: 10), const Text('Could not load achievements'), const SizedBox(height: 10), ElevatedButton(onPressed: onRetry, style: ElevatedButton.styleFrom(backgroundColor: _green), child: const Text('Retry', style: TextStyle(color: Colors.white)))]));
}
