import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'record_form.dart';

class RecordsScreen extends ConsumerStatefulWidget {
  const RecordsScreen({super.key});
  @override
  ConsumerState<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends ConsumerState<RecordsScreen> {
  String? _filter;

  Future<void> _open([Json? existing]) async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => RecordForm(existing: existing)));
  }

  Future<void> _delete(Json r) async {
    if (!await confirmDialog(context, title: 'Delete “${r['name']}”?', body: 'It will be removed from your projections and scenarios. This can\'t be undone.')) return;
    try {
      await ref.read(apiProvider).deleteRecord(r['id'] as String);
      refreshFinancialData(ref);
      if (mounted) showSnack(context, 'Record deleted');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = ref.watch(recordsProvider);
    final cur = ref.watch(currencyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Financial records'), actions: [
        IconButton(tooltip: 'Import a document', icon: const Icon(Icons.document_scanner_outlined), onPressed: () => context.push('/documents')),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _open, icon: const Icon(Icons.add), label: const Text('Add record')),
      body: SafeArea(
        child: PageList(
          onRefresh: () async {
            ref.invalidate(recordsProvider);
            await ref.read(recordsProvider.future).catchError((_) => <Json>[]);
          },
          children: [
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: const Text('All'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null))),
                for (final t in recordTypes.entries)
                  Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(t.value.$1), selected: _filter == t.key, onSelected: (_) => setState(() => _filter = t.key))),
              ]),
            ),
            const SizedBox(height: 12),
            AsyncBody<List<Json>>(
              value: records,
              onRetry: () => ref.invalidate(recordsProvider),
              builder: (all) {
                final list = all.where((r) => _filter == null || r['type'] == _filter).toList();
                if (list.isEmpty) {
                  return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: _filter == null ? 'No records yet' : 'Nothing here yet',
                    body: 'Add income, loans, cards, insurance and other commitments so CASCADE can project your cash flow.',
                    action: FilledButton(onPressed: _open, child: const Text('Add your first record')),
                  );
                }
                return Column(children: [for (final r in list) Padding(padding: const EdgeInsets.only(bottom: 8), child: _RecordTile(r: r, cur: cur, onTap: () => _open(r), onDelete: () => _delete(r)))]);
              },
            ),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.r, required this.cur, required this.onTap, required this.onDelete});
  final Json r;
  final Currency cur;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = recordTypes[r['type']] ?? ('Other', Icons.more_horiz);
    final ver = r['verification'] as String? ?? 'user_provided';
    final isIncome = r['type'] == 'income';
    final freq = r['frequency'] == 'once' ? 'one time' : frequencies[r['frequency']]?.toLowerCase() ?? '';
    return SectionCard(
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: (isIncome ? C.emerald : C.blue).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(t.$2, color: isIncome ? C.emerald : C.blue, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text('${t.$1}${r['start_date'] != null ? ' · $freq · from ${fmtDate(r['start_date'] as String)}' : ''}', style: const TextStyle(fontSize: 12, color: C.muted)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            if (ver == 'verified') const ProvenanceBadge(Provenance.fact),
            if (ver == 'extracted_unverified') const ProvenanceBadge(Provenance.unverified),
            if (ver == 'demo') const ProvenanceBadge(Provenance.demo),
            if (r['estimated'] == true) const ProvenanceBadge(Provenance.estimate),
          ]),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(cur.format(r['amount_minor'] as int), style: TextStyle(fontWeight: FontWeight.w700, color: isIncome ? C.emerald : C.text)),
          PopupMenuButton<String>(
            tooltip: 'More actions',
            icon: const Icon(Icons.more_horiz, color: C.muted),
            onSelected: (v) => v == 'delete' ? onDelete() : onTap(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
          ),
        ]),
      ]),
    );
  }
}
