import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

class ScenariosScreen extends ConsumerStatefulWidget {
  const ScenariosScreen({super.key});
  @override
  ConsumerState<ScenariosScreen> createState() => _ScenariosScreenState();
}

class _ScenariosScreenState extends ConsumerState<ScenariosScreen> {
  bool _discovering = false;
  Json? _result;
  ApiException? _error;
  final Set<int> _saving = {};

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiProvider).discover();
      if (mounted) setState(() => _result = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _save(int i, Json c) async {
    setState(() => _saving.add(i));
    try {
      final live = (_result!['labels'] as Json)['live_ai'] == true;
      final saved = await ref.read(apiProvider).saveScenario({
        'title': c['scenario_title'], 'summary': c['scenario_summary'], 'origin': live ? 'ai' : 'ai_fallback',
        'horizon_days': c['time_horizon_days'], 'disruptions': c['disruptions'], 'assumptions': c['assumptions'],
        'uncertainties': c['uncertainties'], 'source_record_ids': c['source_record_ids'],
      });
      refreshFinancialData(ref);
      if (mounted) context.push('/scenarios/${(saved['scenario'] as Json)['id']}');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving.remove(i));
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(scenariosProvider);
    final cur = ref.watch(currencyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scenarios'), actions: [
        IconButton(tooltip: 'Ask the assistant', icon: const Icon(Icons.chat_bubble_outline), onPressed: () => context.push('/assistant')),
      ]),
      body: SafeArea(
        child: PageList(
          onRefresh: () async => ref.invalidate(scenariosProvider),
          children: [
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [Icon(Icons.auto_awesome, color: C.blue, size: 20), SizedBox(width: 8), Text('Discover compound risks', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))]),
                const SizedBox(height: 6),
                const Text(
                  'AI looks across your real schedule for combinations of events that could squeeze your cash. '
                  'Every proposal is validated against your records, then calculated by a deterministic engine.',
                  style: TextStyle(color: C.muted, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _discovering ? null : _discover,
                  icon: _discovering ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search_rounded),
                  label: Text(_discovering ? 'Analysing your schedule…' : 'Find risks'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: () => _manualSheet(context), icon: const Icon(Icons.tune), label: const Text('Create a what-if manually')),
              ]),
            ),
            if (_error != null) _ErrorCard(e: _error!, onManual: () => _manualSheet(context)),
            if (_result != null) ..._candidates(_result!, cur),
            SectionTitle('Saved scenarios'),
            AsyncBody<List<Json>>(
              value: saved,
              onRetry: () => ref.invalidate(scenariosProvider),
              skeletonHeight: 84,
              builder: (list) => list.isEmpty
                  ? const EmptyState(icon: Icons.account_tree_outlined, title: 'No saved scenarios', body: 'Discover risks or create a what-if, then save it to track how it changes.')
                  : Column(children: [for (final s in list.reversed) Padding(padding: const EdgeInsets.only(bottom: 8), child: _SavedTile(s: s, cur: cur))]),
            ),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }

  List<Widget> _candidates(Json r, Currency cur) {
    final labels = r['labels'] as Json;
    final live = labels['live_ai'] == true;
    final all = (r['candidates'] as List).cast<Json>();
    final ok = all.where((c) => c['validation_status'] != 'rejected').toList();
    final rejected = all.where((c) => c['validation_status'] == 'rejected').toList();
    return [
      SectionTitle('Discovered scenarios', trailing: ProvenanceBadge(live ? Provenance.aiHypothesis : Provenance.ruleBased)),
      if (!live)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text('No live AI model is configured, so these scenarios come from deterministic rules. Calculations are still real.', style: TextStyle(color: C.amber, fontSize: 12)),
        ),
      if (ok.isEmpty) const SectionCard(child: Text('No valid scenarios were found. Add more records or check back later.', style: TextStyle(color: C.muted))),
      for (var i = 0; i < ok.length; i++)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: _CandidateCard(c: ok[i], cur: cur, saving: _saving.contains(i), onSave: () => _save(i, ok[i]))),
      if (rejected.isNotEmpty)
        ExpansionTile(
          title: Text('Rejected by validation (${rejected.length})', style: const TextStyle(fontSize: 13, color: C.muted)),
          children: [for (final c in rejected) ListTile(dense: true, title: Text(c['scenario_title'] as String), subtitle: Text((c['validation_reasons'] as List).join('; ')))],
        ),
    ];
  }

  Future<void> _manualSheet(BuildContext context) async {
    final created = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      showDragHandle: true,
      builder: (_) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom), child: const ManualScenarioSheet()),
    );
    if (created != null && context.mounted) context.push('/scenarios/$created');
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.e, required this.onManual});
  final ApiException e;
  final VoidCallback onManual;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SectionCard(
          borderColor: C.amber.withValues(alpha: 0.6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(e.isAiUnavailable ? Icons.cloud_off_rounded : Icons.info_outline, color: C.amber), const SizedBox(width: 8), Expanded(child: Text(e.isAiUnavailable ? 'AI is unavailable right now' : e.isIncomplete ? 'More information needed' : 'Couldn\'t analyse', style: const TextStyle(fontWeight: FontWeight.w700)))]),
            const SizedBox(height: 6),
            Text(e.message, style: const TextStyle(color: C.muted, fontSize: 13)),
            if (e.isIncomplete && e.details['reasons'] != null) Text((e.details['reasons'] as List).join(' '), style: const TextStyle(fontSize: 13)),
            if (e.isAiUnavailable) TextButton(onPressed: onManual, child: const Text('Create a what-if manually instead')),
          ]),
        ),
      );
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.c, required this.cur, required this.saving, required this.onSave});
  final Json c;
  final Currency cur;
  final bool saving;
  final VoidCallback onSave;
  @override
  Widget build(BuildContext context) {
    final ev = c['evaluation'] as Json?;
    final sf = ev?['shortfall'] as Json?;
    final compound = c['compound_effect'] as Json?;
    final needsInput = c['validation_status'] == 'needs_input';
    return SectionCard(
      borderColor: sf != null ? C.red.withValues(alpha: 0.45) : C.line,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c['scenario_title'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 4),
        Text(c['scenario_summary'] as String, style: const TextStyle(color: C.muted, fontSize: 13)),
        if ((c['trigger_events'] as List).isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final t in (c['trigger_events'] as List)) Text('• $t', style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 10),
        if (needsInput)
          Text('Needs input: ${(c['validation_reasons'] as List).join('; ')}', style: const TextStyle(color: C.amber, fontSize: 13))
        else if (sf != null)
          Text('Simulated: cash could go negative from ${fmtDate(sf['first_date'] as String)}, by up to ${cur.format(sf['max_deficit_minor'] as int)} (${sf['days_negative']} days). Affected: ${(sf['obligations_at_risk'] as List).join(', ')}.', style: const TextStyle(fontSize: 13, color: C.red))
        else
          Text('Simulated: no shortfall. Lowest point ${cur.format((ev?['lowest_balance_minor'] as int?) ?? 0)}.', style: const TextStyle(fontSize: 13, color: C.emerald)),
        if (compound != null) ...[
          const SizedBox(height: 6),
          Text('Compound effect: together ${cur.format(compound['combined_deficit_minor'] as int)} vs ${cur.format((compound['individual_deficits_minor'] as List).cast<int>().fold<int>(0, (a, b) => a > b ? a : b))} for the largest single event.', style: const TextStyle(fontSize: 12, color: C.amber)),
        ],
        const SizedBox(height: 8),
        Text('Why: ${c['rationale']}', style: const TextStyle(fontSize: 12, color: C.muted)),
        if ((c['uncertainties'] as List).isNotEmpty) Text('Uncertain: ${(c['uncertainties'] as List).join('; ')}', style: const TextStyle(fontSize: 12, color: C.muted)),
        Text('Interpretation confidence: ${c['interpretation_confidence']} (qualitative — not a probability this will happen)', style: const TextStyle(fontSize: 11, color: C.muted)),
        const SizedBox(height: 10),
        if (!needsInput) FilledButton.tonalIcon(onPressed: saving ? null : onSave, icon: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.analytics_outlined), label: const Text('Save & analyse')),
      ]),
    );
  }
}

class _SavedTile extends StatelessWidget {
  const _SavedTile({required this.s, required this.cur});
  final Json s;
  final Currency cur;
  @override
  Widget build(BuildContext context) {
    final sf = (s['last_summary'] as Json?)?['shortfall'] as Json?;
    final origin = s['origin'] as String? ?? 'user';
    return SectionCard(
      onTap: () => context.push('/scenarios/${s['id']}'),
      child: Row(children: [
        Icon(sf != null ? Icons.warning_amber_rounded : Icons.check_circle_outline, color: sf != null ? C.red : C.emerald),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(sf != null ? 'Shortfall from ${fmtDate(sf['first_date'] as String)} · up to ${cur.format(sf['max_deficit_minor'] as int)}' : 'No shortfall projected', style: TextStyle(fontSize: 12, color: sf != null ? C.red : C.muted)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            if (origin == 'ai') const ProvenanceBadge(Provenance.aiHypothesis),
            if (origin == 'ai_fallback') const ProvenanceBadge(Provenance.ruleBased),
            if (origin == 'demo') const ProvenanceBadge(Provenance.demo),
          ]),
        ])),
        const Icon(Icons.chevron_right, color: C.muted),
      ]),
    );
  }
}

/// Manual what-if builder: the deterministic path that works with no AI at all.
class ManualScenarioSheet extends ConsumerStatefulWidget {
  const ManualScenarioSheet({super.key});
  @override
  ConsumerState<ManualScenarioSheet> createState() => _ManualScenarioSheetState();
}

class _ManualScenarioSheetState extends ConsumerState<ManualScenarioSheet> {
  final _form = GlobalKey<FormState>();
  String _type = 'income_delay';
  String? _recordId;
  double _days = 10;
  double _pct = 25;
  final _amount = TextEditingController();
  DateTime? _on;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _create(List<Json> incomes, Currency cur) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final rec = incomes.cast<Json?>().firstWhere((r) => r!['id'] == _recordId, orElse: () => null);
    final Json d;
    final String title;
    switch (_type) {
      case 'income_delay':
        d = {'type': 'income_delay', 'record_id': _recordId, 'days': _days.round()};
        title = '${rec?['name'] ?? 'Income'} arrives ${_days.round()} days late';
      case 'income_reduction':
        d = {'type': 'income_reduction', 'record_id': _recordId, 'percent_bps': (_pct * 100).round()};
        title = '${rec?['name'] ?? 'Income'} falls ${_pct.round()}%';
      default:
        d = {'type': 'unexpected_expense', 'on': isoDate(_on!), 'amount_minor': cur.parse(_amount.text), 'label': 'Unexpected expense'};
        title = 'Unexpected ${cur.format(cur.parse(_amount.text)!)} expense';
    }
    try {
      final r = await ref.read(apiProvider).saveScenario({'title': title, 'origin': 'user', 'disruptions': [d], 'source_record_ids': [if (_recordId != null) _recordId]});
      refreshFinancialData(ref);
      if (mounted) Navigator.pop(context, (r['scenario'] as Json)['id'] as String);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(currencyProvider);
    final incomes = (ref.watch(recordsProvider).valueOrNull ?? const []).where((r) => r['type'] == 'income').toList();
    final needsIncome = _type != 'unexpected_expense';
    return SafeArea(
      child: Form(
        key: _form,
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('New what-if', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'What could happen?'),
            items: const [
              DropdownMenuItem(value: 'income_delay', child: Text('Income arrives late')),
              DropdownMenuItem(value: 'income_reduction', child: Text('Income is lower than expected')),
              DropdownMenuItem(value: 'unexpected_expense', child: Text('An unexpected expense')),
            ],
            onChanged: (v) => setState(() => _type = v!),
          ),
          const SizedBox(height: 14),
          if (needsIncome)
            DropdownButtonFormField<String>(
              initialValue: _recordId,
              decoration: const InputDecoration(labelText: 'Which income'),
              items: [const DropdownMenuItem(value: null, child: Text('All income')), for (final r in incomes) DropdownMenuItem(value: r['id'] as String, child: Text(r['name'] as String))],
              onChanged: (v) => setState(() => _recordId = v),
            ),
          if (_type == 'income_delay') ...[
            const SizedBox(height: 10),
            Text('Delay: ${_days.round()} days'),
            Slider(value: _days, min: 1, max: 60, divisions: 59, label: '${_days.round()} days', onChanged: (v) => setState(() => _days = v)),
          ],
          if (_type == 'income_reduction') ...[
            const SizedBox(height: 10),
            Text('Reduction: ${_pct.round()}%'),
            Slider(value: _pct, min: 5, max: 100, divisions: 19, label: '${_pct.round()}%', onChanged: (v) => setState(() => _pct = v)),
          ],
          if (_type == 'unexpected_expense') ...[
            MoneyField(controller: _amount, currency: cur),
            const SizedBox(height: 14),
            DateField(value: _on, onChanged: (d) => setState(() => _on = d), first: DateTime.now(), last: DateTime.now().add(const Duration(days: 365))),
          ],
          const SizedBox(height: 18),
          FilledButton(onPressed: _busy ? null : () => _create(incomes, cur), child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Simulate & save')),
        ]),
      ),
    );
  }
}
