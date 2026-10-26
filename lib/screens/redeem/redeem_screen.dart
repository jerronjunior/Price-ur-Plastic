// lib/screens/redeem/redeem_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Redeem points:   [ Reload ]  [ Shop ]  [ History ]
//   Reload  – top up a mobile number (admin fulfils, status: pending)
//   Shop    – vouchers for partner shops, e.g. ice cream (single-use code)
//   History – everything the user has redeemed, with status
//
// Route:  GoRoute(path: '/redeem', builder: (_, __) => const RedeemScreen())
// Open:   context.push('/redeem');
// The points balance comes from AuthProvider, which already listens to the
// user document, so it updates the moment the redemption transaction commits.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/redemption_models.dart';
import '../../providers/auth_provider.dart';
import '../../services/redemption_service.dart';

const _green = Color(0xFF2E7D32);
const _darkGreen = Color(0xFF1B5E20);
const _bg = Color(0xFFF1F8E9);
const _operators = ['Dialog', 'Mobitel', 'Hutch', 'Airtel'];

class RedeemScreen extends StatefulWidget {
  const RedeemScreen({super.key});

  @override
  State<RedeemScreen> createState() => _RedeemScreenState();
}

class _RedeemScreenState extends State<RedeemScreen> {
  final _service = RedemptionService();
  late final Stream<List<RedemptionItem>> _items;
  late final Stream<List<Redemption>> _history;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _items = _service.itemsStream().asBroadcastStream();
    _history = _service.myRedemptionsStream().asBroadcastStream();
  }

  int get _balance => context.read<AuthProvider>().user?.totalPoints ?? 0;

  // ── Actions ───────────────────────────────────────────────────────────────
  Future<void> _onItemTap(RedemptionItem item) async {
    if (_busy) return;
    if (_balance < item.pointsCost) {
      _snack('You need ${item.pointsCost - _balance} more points for this.');
      return;
    }

    if (item.isReload) {
      final input = await showModalBottomSheet<_ReloadInput>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (_) => _ReloadSheet(item: item),
      );
      if (input == null) return;
      await _redeem(item, phone: input.phone, operator: input.operator);
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('${item.emoji}  ${item.title}'),
          content: Text(
              'Spend ${item.pointsCost} points on this voucher?\n\n'
              'You will get a single-use code to show at '
              '${item.partnerName.isEmpty ? 'the shop' : item.partnerName}. '
              'Valid for ${item.expiryDays} days.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Redeem  ·  ${item.pointsCost} pts')),
          ],
        ),
      );
      if (ok == true) await _redeem(item);
    }
  }

  Future<void> _redeem(RedemptionItem item,
      {String? phone, String? operator}) async {
    setState(() => _busy = true);
    try {
      final result =
          await _service.redeem(item, phone: phone, operator: operator);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => _SuccessDialog(
            item: item, code: result.code, phone: phone, operator: operator),
      );
    } on RedeemException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final points = context.watch<AuthProvider>().user?.totalPoints ?? 0;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          children: [
            Column(
              children: [
                _Header(
                  points: points,
                  onBack: () =>
                      context.canPop() ? context.pop() : context.go('/rewards'),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _CatalogTab(
                        stream: _items,
                        category: kCategoryReload,
                        balance: points,
                        emptyText: 'No reload options yet.\nCheck back soon!',
                        onTap: _onItemTap,
                      ),
                      _CatalogTab(
                        stream: _items,
                        category: kCategoryVoucher,
                        balance: points,
                        emptyText: 'No shop vouchers yet.\nCheck back soon!',
                        onTap: _onItemTap,
                      ),
                      _HistoryTab(stream: _history),
                    ],
                  ),
                ),
              ],
            ),
            if (_busy)
              Container(
                color: Colors.black26,
                child: const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Header + tabs ───────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  const _Header({required this.points, required this.onBack});
  final int points;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [_green, _darkGreen],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: onBack,
                ),
                const Expanded(
                  child: Center(
                    child: Text('REDEEM',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2)),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 10),
            const Text('Your balance',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Icon(Icons.bolt, color: Color(0xFFFFD54F), size: 30),
                Text('$points',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        height: 1.1)),
                const Padding(
                  padding: EdgeInsets.only(left: 6, bottom: 6),
                  child: Text('pts',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const TabBar(
              indicatorColor: Color(0xFFFFD54F),
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white60,
              labelStyle: TextStyle(fontWeight: FontWeight.bold),
              dividerColor: Colors.transparent,
              tabs: [
                Tab(icon: Icon(Icons.phone_android, size: 20), text: 'Reload'),
                Tab(icon: Icon(Icons.storefront, size: 20), text: 'Shop'),
                Tab(icon: Icon(Icons.history, size: 20), text: 'History'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Catalog (Reload / Shop) ─────────────────────────────────────────────────
class _CatalogTab extends StatelessWidget {
  const _CatalogTab({
    required this.stream,
    required this.category,
    required this.balance,
    required this.emptyText,
    required this.onTap,
  });

  final Stream<List<RedemptionItem>> stream;
  final String category;
  final int balance;
  final String emptyText;
  final ValueChanged<RedemptionItem> onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<RedemptionItem>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const _Message(
              icon: Icons.cloud_off, text: 'Could not load rewards.');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: _green));
        }
        final items = snap.data!.where((i) => i.category == category).toList();
        if (items.isEmpty) {
          return _Message(icon: Icons.card_giftcard, text: emptyText);
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) => _ItemCard(
            item: items[i],
            affordable: balance >= items[i].pointsCost,
            missing: items[i].pointsCost - balance,
            onTap: () => onTap(items[i]),
          ),
        );
      },
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.affordable,
    required this.missing,
    required this.onTap,
  });

  final RedemptionItem item;
  final bool affordable;
  final int missing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                  color: _green.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: affordable
                      ? const Color(0xFFE8F5E9)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(item.emoji, style: const TextStyle(fontSize: 28)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: _darkGreen)),
                    if (item.partnerName.isNotEmpty)
                      Text(item.partnerName,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    if (item.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(item.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: affordable ? _green : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('${item.pointsCost} pts',
                        style: TextStyle(
                            color:
                                affordable ? Colors.white : Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ),
                  if (!affordable)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('$missing more',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reload bottom sheet ─────────────────────────────────────────────────────
class _ReloadInput {
  _ReloadInput(this.phone, this.operator);
  final String phone;
  final String operator;
}

class _ReloadSheet extends StatefulWidget {
  const _ReloadSheet({required this.item});
  final RedemptionItem item;

  @override
  State<_ReloadSheet> createState() => _ReloadSheetState();
}

class _ReloadSheetState extends State<_ReloadSheet> {
  final _phone = TextEditingController();
  String _operator = _operators.first;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  /// Accepts 07XXXXXXXX, +947XXXXXXXX, 947XXXXXXXX → normalised to 07XXXXXXXX.
  String? _normalise(String raw) {
    var s = raw.replaceAll(RegExp(r'[\s\-]'), '');
    if (s.startsWith('+94')) s = '0${s.substring(3)}';
    if (s.startsWith('94') && s.length == 11) s = '0${s.substring(2)}';
    return RegExp(r'^07\d{8}$').hasMatch(s) ? s : null;
  }

  void _submit() {
    final n = _normalise(_phone.text);
    if (n == null) {
      setState(() => _error = 'Enter a valid mobile number, e.g. 0771234567');
      return;
    }
    Navigator.pop(context, _ReloadInput(n, _operator));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 20, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 16),
            Text('${item.emoji}  ${item.title}',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _darkGreen)),
            const SizedBox(height: 4),
            Text('${item.pointsCost} points',
                style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 18),
            const Text('Mobile operator',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final op in _operators)
                  ChoiceChip(
                    label: Text(op),
                    selected: _operator == op,
                    showCheckmark: false,
                    selectedColor: _green,
                    labelStyle: TextStyle(
                        color: _operator == op ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.w600),
                    onSelected: (_) => setState(() => _operator = op),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Mobile number',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s\-]')),
                LengthLimitingTextInputFormatter(16),
              ],
              decoration: InputDecoration(
                hintText: '07X XXX XXXX',
                errorText: _error,
                prefixIcon: const Icon(Icons.phone_android),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Text(
              'Double-check the number — reloads cannot be reversed once sent.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submit,
                child: Text('Redeem  ·  ${item.pointsCost} pts'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Success dialog ──────────────────────────────────────────────────────────
class _SuccessDialog extends StatelessWidget {
  const _SuccessDialog(
      {required this.item, this.code, this.phone, this.operator});
  final RedemptionItem item;
  final String? code;
  final String? phone;
  final String? operator;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: _green, size: 56),
            const SizedBox(height: 10),
            const Text('Redeemed!',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _darkGreen)),
            const SizedBox(height: 6),
            Text('${item.emoji} ${item.title}', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (code != null) ...[
              Text(
                  'Show this code at '
                  '${item.partnerName.isEmpty ? 'the shop' : item.partnerName}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF81C784)),
                ),
                child: Text(code!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        color: _darkGreen)),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code!));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')));
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy code'),
              ),
              Text('Valid for ${item.expiryDays} days · single use',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ] else
              Text(
                'We received your request to reload $phone ($operator). '
                'You can track it in the History tab.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade700),
              ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done')),
            ),
          ],
        ),
      ),
    );
  }
}

// ── History ─────────────────────────────────────────────────────────────────
class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.stream});
  final Stream<List<Redemption>> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Redemption>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return const _Message(
              icon: Icons.cloud_off, text: 'Could not load your history.');
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator(color: _green));
        }
        final list = snap.data!;
        if (list.isEmpty) {
          return const _Message(
              icon: Icons.receipt_long,
              text: 'Nothing redeemed yet.\nYour rewards will appear here.');
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _HistoryTile(r: list[i]),
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.r});
  final Redemption r;

  ({String label, Color color}) get _status {
    if (r.isExpired) return (label: 'Expired', color: Colors.grey);
    switch (r.status) {
      case 'pending':
        return (label: 'Processing', color: const Color(0xFFEF6C00));
      case 'active':
        return (label: 'Ready to use', color: _green);
      case 'completed':
        return (label: 'Completed', color: const Color(0xFF1565C0));
      case 'used':
        return (label: 'Used', color: Colors.grey);
      case 'rejected':
        return (label: 'Refunded', color: const Color(0xFFC62828));
      default:
        return (label: r.status, color: Colors.grey);
    }
  }

  String _date(DateTime? d) => d == null
      ? ''
      : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final st = _status;
    final showCode = r.code != null && r.status == 'active' && !r.isExpired;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: _green.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(r.emoji, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.itemTitle,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: _darkGreen)),
                    Text(
                      '${_date(r.createdAt)}  ·  ${r.pointsSpent} pts'
                      '${r.isReload && r.phone != null ? '  ·  ${r.phone}' : ''}',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: st.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(st.label,
                    style: TextStyle(
                        color: st.color,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (r.status == 'rejected')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${r.pointsSpent} points were returned to your balance.',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          if (showCode) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.code!,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            color: _darkGreen)),
                  ),
                  if (r.expiresAt != null)
                    Text('exp ${_date(r.expiresAt)}',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: r.code!));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Code copied')));
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
