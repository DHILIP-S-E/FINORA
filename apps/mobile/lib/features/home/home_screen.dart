import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../assistant/assistant_widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cf = ref.watch(cashflowProvider(60));
    final cur = ref.watch(currencyProvider);
    final alerts = ref.watch(alertsProvider);
    final unread = alerts.valueOrNull?.where((a) => a['read'] != true).length ?? 0;
    final profile = ref.watch(profileProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CASCADE', style: TextStyle(letterSpacing: 2.5, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: unread > 0 ? 'Alerts, $unread unread' : 'Alerts',
            onPressed: () => context.push('/alerts'),
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none_rounded)),
          ),
        ],
      ),
      body: SafeArea(
        child: PageList(
          onRefresh: () async {
            refreshFinancialData(ref);
            await ref.read(cashflowProvider(60).future).catchError((_) => <String, dynamic>{});
          },
          children: [
            if (profile?['is_demo'] == true) const _DemoBanner(),
            AsyncBody<Json>(
              value: cf,
              onRetry: () => ref.invalidate(cashflowProvider),
              skeletonHeight: 140,
              builder: (d) => _Content(data: d, cur: cur),
            ),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: C.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.amber.withValues(alpha: 0.4))),
        child: const Row(children: [
          Icon(Icons.science_outlined, color: C.amber, size: 18),
          SizedBox(width: 10),
          Expanded(child: Text('Demo mode · all figures are synthetic and belong to a fictional freelancer.', style: TextStyle(fontSize: 12))),
        ]),
      );
}

class _Content extends ConsumerWidget {
  const _Content({required this.data, required this.cur});
  final Json data;
  final Currency cur;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actual = data['actual_balance'] as Json;
    final proj = data['projection'] as Json;
    final summary = proj['summary'] as Json;
    final complete = summary['complete'] == true;
    final shortfall = summary['shortfall'] as Json?;
    final events = (data['events'] as List).cast<Json>();
    final missing = (data['missing_information'] as List).cast<String>();
    final bal = actual['amount_minor'] as int?;
    final stale = actual['stale_days'] as int?;
    final upcomingOut = events.where((e) => (e['delta_minor'] as int) < 0).take(4).toList();
    final upcomingIn = events.where((e) => (e['delta_minor'] as int) > 0).take(2).toList();
    final scenarios = ref.watch(scenariosProvider).valueOrNull ?? const [];
    Json? top;
    for (final s in scenarios) {
      final sf = (s['last_summary'] as Json?)?['shortfall'] as Json?;
      if (sf != null && (top == null || (sf['max_deficit_minor'] as int) > (((top['last_summary'] as Json)['shortfall'] as Json)['max_deficit_minor'] as int))) top = s;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Available cash', style: TextStyle(color: C.muted)),
            const Spacer(),
            if (data['is_demo'] == true) const ProvenanceBadge(Provenance.demo) else const ProvenanceBadge(Provenance.fact),
          ]),
          const SizedBox(height: 6),
          if (bal == null) ...[
            const Text('Not set', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: C.muted)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => context.push('/setup'), child: const Text('Add your cash balance')),
          ] else ...[
            Text(cur.format(bal), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: balanceColor(bal))),
            const SizedBox(height: 2),
            Text(
              'As of ${fmtDate(actual['as_of'] as String?, year: true)} · reported by you${stale != null && stale > 7 ? ' · $stale days old' : ''}',
              style: TextStyle(fontSize: 12, color: stale != null && stale > 7 ? C.amber : C.muted),
            ),
          ],
        ]),
      ),
      if (!complete && bal != null) ...[const SizedBox(height: 12), _Info(summary['incomplete_reasons'].toString(), C.amber)],
      if (complete) ...[
        const SectionTitle('Projected cash flow'),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (shortfall != null)
              _Info(
                'Cash could drop below zero from ${fmtDate(shortfall['first_date'] as String)} — by up to ${cur.format(shortfall['max_deficit_minor'] as int)}. '
                'Affected: ${(shortfall['obligations_at_risk'] as List).join(', ')}.',
                C.red,
                icon: Icons.warning_amber_rounded,
              )
            else
              _Info('No shortfall projected in the next 60 days. Lowest point: ${cur.format(summary['lowest_balance_minor'] as int)} on ${fmtDate(summary['lowest_balance_date'] as String?)}.', C.emerald, icon: Icons.check_circle_outline),
            const SizedBox(height: 12),
            BalanceChart(daily: (proj['daily'] as List).cast<Json>(), currency: cur),
            const SizedBox(height: 6),
            const Text('Projection from your records and estimates — not a prediction.', style: TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ),
      ],
      if (missing.isNotEmpty) ...[
        const SectionTitle('Needs attention'),
        SectionCard(
          onTap: () => context.go('/records'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final m in missing.take(3)) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.info_outline, size: 16, color: C.amber), const SizedBox(width: 8), Expanded(child: Text(m, style: const TextStyle(fontSize: 13)))])),
            if (missing.length > 3) Text('+${missing.length - 3} more', style: const TextStyle(color: C.muted, fontSize: 12)),
          ]),
        ),
      ],
      const SectionTitle('Highest-priority risk'),
      if (top != null) _TopRisk(scenario: top, cur: cur) else _NoRisk(hasData: complete),
      const SizedBox(height: 12),
      const ScenarioPrompt(),
      const SectionTitle('Upcoming'),
      if (upcomingOut.isEmpty && upcomingIn.isEmpty)
        const SectionCard(child: Text('Nothing scheduled yet. Add income and obligations in Records.', style: TextStyle(color: C.muted)))
      else
        SectionCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final e in [...upcomingIn, ...upcomingOut]) _EventTile(e: e, cur: cur),
          ]),
        ),
      const SectionTitle('Recent updates'),
      _RecentUpdates(),
    ]);
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.e, required this.cur});
  final Json e;
  final Currency cur;
  @override
  Widget build(BuildContext context) {
    final d = e['delta_minor'] as int;
    return ListTile(
      dense: true,
      title: Text(e['label'] as String),
      subtitle: Row(children: [Text(fmtDate(e['date'] as String)), const SizedBox(width: 8), StatusChip(e['status'] as String)]),
      trailing: Text(cur.format(d, showSign: true), style: TextStyle(fontWeight: FontWeight.w600, color: d > 0 ? C.emerald : C.text)),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.text, this.color, {this.icon = Icons.info_outline});
  final String text;
  final Color color;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35))),
        ]),
      );
}

class _TopRisk extends StatelessWidget {
  const _TopRisk({required this.scenario, required this.cur});
  final Json scenario;
  final Currency cur;
  @override
  Widget build(BuildContext context) {
    final sf = (scenario['last_summary'] as Json)['shortfall'] as Json;
    return SectionCard(
      borderColor: C.red.withValues(alpha: 0.5),
      onTap: () => context.push('/scenarios/${scenario['id']}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.warning_amber_rounded, color: C.red, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(scenario['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
          const Icon(Icons.chevron_right, color: C.muted),
        ]),
        const SizedBox(height: 8),
        Text('If this happened, cash could go negative from ${fmtDate(sf['first_date'] as String)} by up to ${cur.format(sf['max_deficit_minor'] as int)}.', style: const TextStyle(color: C.muted, fontSize: 13)),
        const SizedBox(height: 8),
        const Wrap(spacing: 6, children: [ProvenanceBadge(Provenance.simulated), ProvenanceBadge(Provenance.unverified)]),
      ]),
    );
  }
}

class _NoRisk extends StatelessWidget {
  const _NoRisk({required this.hasData});
  final bool hasData;
  @override
  Widget build(BuildContext context) => SectionCard(
        onTap: () => context.go('/scenarios'),
        child: Row(children: [
          const Icon(Icons.auto_awesome, color: C.blue),
          const SizedBox(width: 12),
          Expanded(child: Text(hasData ? 'No risk scenarios saved yet. Let CASCADE look for combinations that could cause a shortfall.' : 'Add your cash balance and obligations to discover risks.', style: const TextStyle(color: C.muted))),
          const Icon(Icons.chevron_right, color: C.muted),
        ]),
      );
}

class _RecentUpdates extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(alertsProvider);
    return a.when(
      loading: () => const Skeleton(height: 64),
      error: (e, _) => const SizedBox(),
      data: (items) => items.isEmpty
          ? const SectionCard(child: Text('No updates yet. You\'ll see changes to your projection here.', style: TextStyle(color: C.muted)))
          : SectionCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final x in items.take(3))
                  ListTile(
                    dense: true,
                    leading: Icon(x['type'] == 'missing_information' ? Icons.info_outline : Icons.show_chart, color: x['read'] == true ? C.muted : C.amber),
                    title: Text(x['title'] as String),
                    subtitle: Text(x['body'] as String, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => context.push('/alerts'),
                  ),
              ]),
            ),
    );
  }
}
