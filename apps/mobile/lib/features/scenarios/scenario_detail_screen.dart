import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

final scenarioDetailProvider = FutureProvider.autoDispose.family<_Detail, String>((ref, id) async {
  final api = ref.watch(apiProvider);
  final got = await api.getScenario(id);
  final cmp = await api.compare(id);
  return _Detail(got, cmp);
});

class _Detail {
  _Detail(this.scenario, this.compare);
  final Json scenario;
  final Json compare;
}

class ScenarioDetailScreen extends ConsumerStatefulWidget {
  const ScenarioDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ScenarioDetailScreen> createState() => _ScenarioDetailScreenState();
}

class _ScenarioDetailScreenState extends ConsumerState<ScenarioDetailScreen> {
  List<Json>? _edited; // user-modified assumptions
  Json? _altCompare;
  bool _rerunning = false;
  Json? _interventions;
  bool _loadingInterventions = false;

  Future<void> _rerun() async {
    setState(() => _rerunning = true);
    try {
      final r = await ref.read(apiProvider).compare(widget.id, alternative: _edited);
      if (mounted) setState(() => _altCompare = r);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _rerunning = false);
    }
  }

  Future<void> _loadInterventions() async {
    setState(() => _loadingInterventions = true);
    try {
      final r = await ref.read(apiProvider).interventions(widget.id);
      if (mounted) setState(() => _interventions = r);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _loadingInterventions = false);
    }
  }

  Future<void> _delete() async {
    if (!await confirmDialog(context, title: 'Delete scenario?', body: 'The scenario and its saved simulation runs will be removed.')) return;
    try {
      await ref.read(apiProvider).deleteScenario(widget.id);
      refreshFinancialData(ref);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(scenarioDetailProvider(widget.id));
    final cur = ref.watch(currencyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scenario'), actions: [IconButton(tooltip: 'Delete scenario', icon: const Icon(Icons.delete_outline), onPressed: _delete)]),
      body: SafeArea(
        child: PageList(children: [
          AsyncBody<_Detail>(value: detail, onRetry: () => ref.invalidate(scenarioDetailProvider(widget.id)), skeletonHeight: 160, builder: (d) => _body(d, cur)),
          const DisclaimerFooter(),
        ]),
      ),
    );
  }

  Widget _body(_Detail d, Currency cur) {
    final sc = d.scenario['scenario'] as Json;
    final replay = d.scenario['replay'] as Json?;
    final risk = d.compare['baseline_vs_risk'] as Json;
    final base = risk['baseline'] as Json;
    final scen = risk['alternative'] as Json;
    final alt = _altCompare == null ? null : (_altCompare!['risk_vs_alternative'] as Json?)?['alternative'] as Json?;
    final sens = ((_altCompare ?? d.compare)['sensitivity'] as List).cast<Json>();
    final labels = <String, String>{for (final e in (scen['ledger'] as List).cast<Json>()) e['event_id'] as String: e['label'] as String};
    final disruptions = _edited ?? (sc['disruptions'] as List).cast<Json>();
    final explanation = (_altCompare ?? d.compare)['explanation'] as String?;
    final expSource = (_altCompare ?? d.compare)['explanation_source'] as String?;
    final shown = alt ?? scen;
    final origin = sc['origin'] as String? ?? 'user';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(sc['title'] as String, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      if ((sc['summary'] as String?)?.isNotEmpty == true) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sc['summary'] as String, style: const TextStyle(color: C.muted))),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (origin == 'ai') const ProvenanceBadge(Provenance.aiHypothesis),
        if (origin == 'ai_fallback') const ProvenanceBadge(Provenance.ruleBased),
        if (origin == 'demo') const ProvenanceBadge(Provenance.demo),
        const ProvenanceBadge(Provenance.simulated),
        const ProvenanceBadge(Provenance.unverified),
      ]),
      const SectionTitle('Baseline vs this scenario'),
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BalanceChart(daily: (base['daily'] as List).cast<Json>(), compare: (shown['daily'] as List).cast<Json>(), currency: cur),
          const SizedBox(height: 8),
          Row(children: [
            const _Legend(color: C.muted, label: 'Baseline'),
            const SizedBox(width: 16),
            _Legend(color: C.red, label: alt != null ? 'Your what-if' : 'Scenario'),
          ]),
          const SizedBox(height: 4),
          const Text('A hypothetical, not a forecast. It shows what could happen if these assumptions held.', style: TextStyle(fontSize: 11, color: C.muted)),
        ]),
      ),
      const SizedBox(height: 12),
      _MetricsTable(cur: cur, base: base, scen: scen, alt: alt, labels: labels),
      if (explanation != null) ...[
        const SectionTitle('Explanation'),
        SectionCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(explanation, style: const TextStyle(height: 1.45)),
          const SizedBox(height: 8),
          Text(expSource == 'gemini' ? 'Written by AI from the verified numbers above; every figure is checked against the engine output.' : 'Generated from the verified calculation (no AI used for this text).', style: const TextStyle(fontSize: 11, color: C.muted)),
        ])),
      ],
      const SectionTitle('Assumptions'),
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < disruptions.length; i++) _DisruptionEditor(d: disruptions[i], orig: (sc['disruptions'] as List).cast<Json>()[i], cur: cur, onChanged: (nd) => setState(() => _edited = [for (var j = 0; j < disruptions.length; j++) j == i ? nd : disruptions[j]])),
          if (_edited != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: FilledButton.icon(onPressed: _rerunning ? null : _rerun, icon: _rerunning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow_rounded), label: const Text('Re-run with my changes'))),
              const SizedBox(width: 8),
              TextButton(onPressed: () => setState(() {
                    _edited = null;
                    _altCompare = null;
                  }), child: const Text('Reset')),
            ]),
          ],
          const SizedBox(height: 6),
          for (final u in ((shown['excluded_or_unknown'] as List).cast<String>()).take(4)) Padding(padding: const EdgeInsets.only(top: 2), child: Text('Not modelled: $u', style: const TextStyle(fontSize: 11, color: C.muted))),
        ]),
      ),
      if (sens.isNotEmpty) ...[
        const SectionTitle('What matters most'),
        SectionCard(child: Column(children: [for (final s in sens.take(5)) _SensitivityBar(s: s, max: sens.first['impact_minor'] as int, cur: cur)])),
      ],
      const SectionTitle('Reduce the risk'),
      if (_interventions == null)
        OutlinedButton.icon(onPressed: _loadingInterventions ? null : _loadInterventions, icon: _loadingInterventions ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.lightbulb_outline), label: const Text('Evaluate possible interventions'))
      else
        _Interventions(data: _interventions!, cur: cur),
      if (replay != null) ...[
        const SizedBox(height: 16),
        Row(children: [
          Icon(replay['matches_stored_result'] == true ? Icons.verified_outlined : Icons.error_outline, size: 16, color: replay['matches_stored_result'] == true ? C.emerald : C.red),
          const SizedBox(width: 6),
          Expanded(child: Text(replay['matches_stored_result'] == true ? 'Reproducible: re-running the saved inputs gives the same result.' : 'The saved result did not match a re-run.', style: const TextStyle(fontSize: 12, color: C.muted))),
        ]),
      ],
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(children: [Container(width: 14, height: 3, color: color), const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 12, color: C.muted))]);
}

class _MetricsTable extends StatelessWidget {
  const _MetricsTable({required this.cur, required this.base, required this.scen, required this.alt, required this.labels});
  final Currency cur;
  final Json base, scen;
  final Json? alt;
  final Map<String, String> labels;

  String _low(Json r) => cur.format(r['lowest_balance_minor'] as int);
  String _date(Json r) => (r['shortfall'] as Json?) == null ? 'None' : fmtDate((r['shortfall'] as Json)['first_date'] as String);
  String _amt(Json r) => (r['shortfall'] as Json?) == null ? '—' : cur.format((r['shortfall'] as Json)['max_deficit_minor'] as int);
  String _obl(Json r) {
    final s = r['shortfall'] as Json?;
    if (s == null) return '—';
    final names = {for (final id in (s['obligations_at_risk'] as List).cast<String>()) labels[id] ?? id.split('@').first};
    return names.isEmpty ? '—' : names.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String a, String b, [String? c, Color? bc]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(k, style: const TextStyle(color: C.muted, fontSize: 12))),
            Expanded(flex: 3, child: Text(a, style: const TextStyle(fontSize: 13))),
            Expanded(flex: 4, child: Text(b, style: TextStyle(fontSize: 13, color: bc, fontWeight: FontWeight.w600))),
            if (c != null) Expanded(flex: 4, child: Text(c, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          ]),
        );
    final hasAlt = alt != null;
    return SectionCard(
      child: Column(children: [
        Row(children: [
          const Expanded(flex: 3, child: SizedBox()),
          const Expanded(flex: 3, child: Text('Baseline', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          const Expanded(flex: 4, child: Text('Scenario', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.red))),
          if (hasAlt) const Expanded(flex: 4, child: Text('Your what-if', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: C.blue))),
        ]),
        const Divider(),
        row('Lowest balance', _low(base), _low(scen), hasAlt ? _low(alt!) : null, (scen['lowest_balance_minor'] as int) < 0 ? C.red : null),
        row('First shortfall', _date(base), _date(scen), hasAlt ? _date(alt!) : null, (scen['shortfall'] != null) ? C.red : null),
        row('Shortfall (max)', _amt(base), _amt(scen), hasAlt ? _amt(alt!) : null, (scen['shortfall'] != null) ? C.red : null),
        row('Days negative', '${(base['shortfall'] as Json?)?['days_negative'] ?? 0}', '${(scen['shortfall'] as Json?)?['days_negative'] ?? 0}', hasAlt ? '${(alt!['shortfall'] as Json?)?['days_negative'] ?? 0}' : null),
        row('Obligations at risk', _obl(base), _obl(scen), hasAlt ? _obl(alt!) : null),
        if ((scen['order_sensitive_dates'] as List).isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('Order-sensitive on ${(scen['order_sensitive_dates'] as List).map((e) => fmtDate(e as String)).join(', ')}: the result depends on which payment clears first.', style: const TextStyle(fontSize: 11, color: C.amber))),
      ]),
    );
  }
}

class _DisruptionEditor extends StatelessWidget {
  const _DisruptionEditor({required this.d, required this.orig, required this.cur, required this.onChanged});
  final Json d;
  final Json orig;
  final Currency cur;
  final ValueChanged<Json> onChanged;
  @override
  Widget build(BuildContext context) {
    switch (d['type']) {
      case 'income_delay':
        final days = (d['days'] as int).toDouble();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Income arrives ${days.round()} days late', style: const TextStyle(fontWeight: FontWeight.w600)),
          Slider(value: days.clamp(1, 90), min: 1, max: 90, divisions: 89, label: '${days.round()} days', onChanged: (v) => onChanged({...d, 'days': v.round()})),
        ]);
      case 'income_reduction':
        final pct = (d['percent_bps'] as int) / 100;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Income reduced by ${pct.round()}%', style: const TextStyle(fontWeight: FontWeight.w600)),
          Slider(value: pct.clamp(1, 100).toDouble(), min: 1, max: 100, divisions: 99, label: '${pct.round()}%', onChanged: (v) => onChanged({...d, 'percent_bps': (v * 100).round()})),
        ]);
      case 'unexpected_expense':
        final amt = (d['amount_minor'] as int);
        final base = (orig['amount_minor'] as int) == 0 ? 1 : orig['amount_minor'] as int;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Unexpected expense of ${cur.format(amt)} on ${fmtDate(d['on'] as String)}', style: const TextStyle(fontWeight: FontWeight.w600)),
          Slider(
            value: (amt / base).clamp(0.1, 3.0),
            min: 0.1, max: 3.0, divisions: 29, label: '${((amt / base) * 100).round()}% of original',
            onChanged: (v) => onChanged({...d, 'amount_minor': (base * v).round().clamp(1, 1 << 50)}),
          ),
        ]);
      default:
        return Text(d['type'].toString());
    }
  }
}

class _SensitivityBar extends StatelessWidget {
  const _SensitivityBar({required this.s, required this.max, required this.cur});
  final Json s;
  final int max;
  final Currency cur;
  @override
  Widget build(BuildContext context) {
    final impact = (s['impact_minor'] as int?) ?? 0;
    final frac = max == 0 ? 0.0 : (impact.abs() / max.abs()).clamp(0.02, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s['assumption'] as String, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: frac, minHeight: 8, color: C.amber, backgroundColor: C.line))),
          const SizedBox(width: 10),
          Text('${cur.format(impact, compact: true)} swing', style: const TextStyle(fontSize: 11, color: C.muted)),
        ]),
      ]),
    );
  }
}

class _Interventions extends StatelessWidget {
  const _Interventions({required this.data, required this.cur});
  final Json data;
  final Currency cur;
  @override
  Widget build(BuildContext context) {
    final list = (data['candidates'] as List).cast<Json>();
    if (list.isEmpty) return SectionCard(child: Text(data['note'] as String? ?? 'No interventions needed.', style: const TextStyle(color: C.muted)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final c in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SectionCard(
            borderColor: c['resolves_shortfall'] == true ? C.emerald.withValues(alpha: 0.5) : C.line,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(c['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
                if (c['resolves_shortfall'] == true) const Icon(Icons.check_circle, color: C.emerald, size: 18),
              ]),
              const SizedBox(height: 4),
              Text(c['description'] as String, style: const TextStyle(fontSize: 13, color: C.muted)),
              const SizedBox(height: 8),
              Text(c['resolves_shortfall'] == true ? 'Simulated: this removes the projected shortfall.' : 'Simulated: shortfall falls to ${cur.format(c['remaining_shortfall_minor'] as int)} (from first date ${fmtDate(c['first_shortfall_date'] as String?)}).', style: TextStyle(fontSize: 13, color: c['resolves_shortfall'] == true ? C.emerald : C.amber)),
              for (final t in (c['trade_offs'] as List)) Padding(padding: const EdgeInsets.only(top: 3), child: Text('Trade-off: $t', style: const TextStyle(fontSize: 12, color: C.muted))),
              for (final a in (c['required_user_actions'] as List)) Padding(padding: const EdgeInsets.only(top: 3), child: Text('Needs: $a', style: const TextStyle(fontSize: 12, color: C.amber))),
            ]),
          ),
        ),
      Text(data['note'] as String? ?? '', style: const TextStyle(fontSize: 11, color: C.muted)),
    ]);
  }
}
