import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});
  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      final r = await ref.read(apiProvider).recalculate();
      ref.invalidate(alertsProvider);
      if (mounted) showSnack(context, (r['count'] as int) == 0 ? 'No new changes found.' : '${r['count']} new alert(s).');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _open(Json a) async {
    final api = ref.read(apiProvider);
    if (a['read'] != true) {
      await api.patchAlert(a['id'] as String, {'read': true});
      ref.invalidate(alertsProvider);
    }
    if (!mounted) return;
    if (a['scenario_id'] != null) context.push('/scenarios/${a['scenario_id']}');
  }

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts'), actions: [
        IconButton(tooltip: 'Notification settings', icon: const Icon(Icons.tune), onPressed: () => context.push('/notification-settings')),
      ]),
      body: SafeArea(
        child: PageList(
          onRefresh: () async => ref.invalidate(alertsProvider),
          children: [
            OutlinedButton.icon(onPressed: _checking ? null : _check, icon: _checking ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh), label: const Text('Check for changes now')),
            const SizedBox(height: 12),
            AsyncBody<List<Json>>(
              value: alerts,
              onRetry: () => ref.invalidate(alertsProvider),
              skeletonHeight: 80,
              builder: (list) => list.isEmpty
                  ? const EmptyState(icon: Icons.notifications_none_rounded, title: 'No alerts', body: 'You\'ll be told when a projected shortfall appears, income dates move, or information is missing.')
                  : Column(children: [
                      for (final a in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Dismissible(
                            key: ValueKey(a['id']),
                            direction: DismissDirection.endToStart,
                            background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(16)), child: const Icon(Icons.close)),
                            onDismissed: (_) async {
                              await ref.read(apiProvider).patchAlert(a['id'] as String, {'dismissed': true});
                              ref.invalidate(alertsProvider);
                            },
                            child: SectionCard(
                              onTap: () => _open(a),
                              borderColor: a['read'] == true ? C.line : C.amber.withValues(alpha: 0.5),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Icon(a['type'] == 'missing_information' ? Icons.info_outline : Icons.show_chart, color: a['read'] == true ? C.muted : C.amber, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(a['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
                                  Text(fmtDate(a['created_at'] as String), style: const TextStyle(fontSize: 11, color: C.muted)),
                                ]),
                                const SizedBox(height: 6),
                                Text(a['body'] as String, style: const TextStyle(fontSize: 13)),
                                Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    dense: true,
                                    title: const Text('Why am I seeing this?', style: TextStyle(fontSize: 12, color: C.blue)),
                                    children: [Align(alignment: Alignment.centerLeft, child: Text(a['why'] as String, style: const TextStyle(fontSize: 12, color: C.muted, height: 1.4)))],
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                    ]),
            ),
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Alerts describe possibilities based on your data, not certainties. Swipe left to dismiss.', style: TextStyle(fontSize: 11, color: C.muted))),
          ],
        ),
      ),
    );
  }
}

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});
  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  Json? _p;
  final _threshold = TextEditingController();
  bool _busy = false;

  static const _types = {
    'new_shortfall': 'Newly projected cash shortfalls',
    'income_date_changed': 'Changes in expected income dates',
    'material_obligation': 'New obligations that create material risk',
    'missing_information': 'Missing information blocking reliable simulation',
    'scenario_changed': 'Significant changes in scenario outcomes',
  };

  @override
  void initState() {
    super.initState();
    ref.read(apiProvider).getPrefs().then((p) {
      if (!mounted) return;
      final cur = ref.read(currencyProvider);
      setState(() {
        _p = p;
        _threshold.text = cur.plain(p['min_shortfall_minor'] as int);
      });
    }).catchError((Object e) {
      if (mounted) showSnack(context, errorText(e));
    });
  }

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cur = ref.read(currencyProvider);
    final thr = cur.parse(_threshold.text.isEmpty ? '0' : _threshold.text);
    if (thr == null || thr < 0) return showSnack(context, 'Enter a valid threshold.');
    setState(() => _busy = true);
    try {
      final body = {
        'push_enabled': _p!['push_enabled'], 'min_shortfall_minor': thr, 'quiet_hours': _p!['quiet_hours'],
        'utc_offset_minutes': DateTime.now().timeZoneOffset.inMinutes, 'fcm_token': _p!['fcm_token'], 'alert_types': _p!['alert_types'],
      };
      await ref.read(apiProvider).putPrefs(body);
      if (mounted) showSnack(context, 'Notification settings saved');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(currencyProvider);
    final p = _p;
    if (p == null) return Scaffold(appBar: AppBar(title: const Text('Notifications')), body: const Padding(padding: EdgeInsets.all(16), child: Skeleton(height: 120)));
    final q = p['quiet_hours'] as Json?;
    final types = (p['alert_types'] as List).cast<String>();
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: PageList(children: [
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Push notifications'), subtitle: const Text('Alerts always appear in the app; this controls phone notifications. Push messages never include amounts.'), value: p['push_enabled'] == true, onChanged: (v) => setState(() => p['push_enabled'] = v)),
          const SectionTitle('Only alert me about shortfalls above'),
          MoneyField(controller: _threshold, currency: cur, label: 'Threshold', required: false, allowZero: true, helper: '0 = any projected shortfall'),
          const SectionTitle('Quiet hours'),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Silence push during quiet hours'), value: q != null, onChanged: (v) => setState(() => p['quiet_hours'] = v ? {'start_hour': 22, 'end_hour': 7} : null)),
          if (q != null)
            Row(children: [
              Expanded(child: DropdownButtonFormField<int>(initialValue: q['start_hour'] as int, decoration: const InputDecoration(labelText: 'From'), items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00'))], onChanged: (v) => setState(() => q['start_hour'] = v))),
              const SizedBox(width: 12),
              Expanded(child: DropdownButtonFormField<int>(initialValue: q['end_hour'] as int, decoration: const InputDecoration(labelText: 'Until'), items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00'))], onChanged: (v) => setState(() => q['end_hour'] = v))),
            ]),
          const SectionTitle('Alert types'),
          for (final t in _types.entries)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.value, style: const TextStyle(fontSize: 14)),
              value: types.contains(t.key),
              onChanged: (v) => setState(() => v == true ? types.add(t.key) : types.remove(t.key)),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          const SizedBox(height: 8),
          const Text('Duplicate alerts for the same unchanged situation are suppressed, and at most 3 pushes are sent per day.', style: TextStyle(fontSize: 11, color: C.muted)),
        ]),
      ),
    );
  }
}
