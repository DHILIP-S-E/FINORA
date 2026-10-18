import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Renders an assistant response with facts / assumptions / hypotheses clearly separated,
/// and an explicit confirm step before anything is saved.
class AssistantResponseView extends ConsumerStatefulWidget {
  const AssistantResponseView({super.key, required this.response});
  final Json response;
  @override
  ConsumerState<AssistantResponseView> createState() => _AssistantResponseViewState();
}

class _AssistantResponseViewState extends ConsumerState<AssistantResponseView> {
  bool _saving = false;

  Future<void> _save() async {
    final p = widget.response['proposed_scenario'] as Json;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(apiProvider).saveScenario({
        'title': p['title'], 'origin': 'natural_language', 'horizon_days': p['horizon_days'],
        'disruptions': p['disruptions'], 'source_record_ids': p['source_record_ids'] ?? [],
        'assumptions': widget.response['assumptions'] ?? [],
      });
      refreshFinancialData(ref);
      if (mounted) context.push('/scenarios/${(saved['scenario'] as Json)['id']}');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<String> _list(String k) => ((widget.response[k] as List?) ?? const []).map((e) => e.toString()).toList();

  @override
  Widget build(BuildContext context) {
    final r = widget.response;
    final live = r['live_ai'] == true;
    final source = r['answer_source'];
    final proposed = r['proposed_scenario'] as Json?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (source == 'gemini') const ProvenanceBadge(Provenance.aiHypothesis) else if (!live) const ProvenanceBadge(Provenance.ruleBased),
        if (r['simulation'] != null) const ProvenanceBadge(Provenance.simulated),
      ]),
      const SizedBox(height: 10),
      Text(r['answer']?.toString() ?? '', style: const TextStyle(height: 1.45)),
      if (_list('facts').isNotEmpty) _Group('Facts from your records & calculations', Icons.fact_check_outlined, C.emerald, _list('facts')),
      if (_list('assumptions').isNotEmpty) _Group('Assumptions in this what-if', Icons.tune, C.amber, _list('assumptions')),
      if (_list('hypotheses').isNotEmpty) _Group('Hypotheses (not predictions)', Icons.lightbulb_outline, C.blue, _list('hypotheses')),
      if (((r['citations'] as List?) ?? const []).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in (r['citations'] as List).cast<Json>())
              Chip(
                avatar: Icon(c['type'] == 'record' ? Icons.receipt_long_outlined : Icons.calculate_outlined, size: 14),
                label: Text((c['label'] as String?)?.isNotEmpty == true ? c['label'] as String : c['type'].toString(), style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
              ),
          ]),
        ),
      if (proposed != null) ...[
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.bookmark_add_outlined),
          label: const Text('Confirm & save this scenario'),
        ),
        const Padding(padding: EdgeInsets.only(top: 6), child: Text('Nothing is saved until you confirm.', style: TextStyle(color: C.muted, fontSize: 12))),
      ],
    ]);
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.icon, this.color, this.items);
  final String title;
  final IconData icon;
  final Color color;
  final List<String> items;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, size: 16, color: color), const SizedBox(width: 6), Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color))]),
          const SizedBox(height: 4),
          for (final i in items) Padding(padding: const EdgeInsets.only(left: 22, top: 2), child: Text('• $i', style: const TextStyle(fontSize: 13, color: C.muted))),
        ]),
      );
}

/// Natural-language scenario input used on Home ("My client may pay me 10 days late").
class ScenarioPrompt extends ConsumerStatefulWidget {
  const ScenarioPrompt({super.key});
  @override
  ConsumerState<ScenarioPrompt> createState() => _ScenarioPromptState();
}

class _ScenarioPromptState extends ConsumerState<ScenarioPrompt> {
  final _c = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final resp = await ref.read(apiProvider).assistant(text);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: C.surface,
        showDragHandle: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
            Text('“$text”', style: const TextStyle(color: C.muted, fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            AssistantResponseView(response: resp),
          ]),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Explore a scenario', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 4),
          const Text('Describe a “what if” in your own words.', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _ask(),
            maxLength: 300,
            decoration: InputDecoration(
              hintText: 'My client may pay me 10 days late',
              counterText: '',
              suffixIcon: _busy
                  ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Run scenario', icon: const Icon(Icons.arrow_upward_rounded, color: C.emerald), onPressed: _ask),
            ),
          ),
        ]),
      );
}
