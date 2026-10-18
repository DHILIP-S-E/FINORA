import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

enum _View { daily, weekly, monthly }

class CashflowScreen extends ConsumerStatefulWidget {
  const CashflowScreen({super.key});
  @override
  ConsumerState<CashflowScreen> createState() => _CashflowScreenState();
}

class _CashflowScreenState extends ConsumerState<CashflowScreen> {
  _View _view = _View.daily;

  int get _horizon => switch (_view) { _View.daily => 30, _View.weekly => 90, _View.monthly => 365 };

  @override
  Widget build(BuildContext context) {
    final cf = ref.watch(cashflowProvider(_horizon));
    final cur = ref.watch(currencyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cash flow')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEventForm(context, ref, cur),
        icon: const Icon(Icons.add),
        label: const Text('Add event'),
      ),
      body: SafeArea(
        child: PageList(
          onRefresh: () async {
            refreshFinancialData(ref);
            await ref.read(cashflowProvider(_horizon).future).catchError((_) => <String, dynamic>{});
          },
          children: [
            SegmentedButton<_View>(
              segments: const [
                ButtonSegment(value: _View.daily, label: Text('Daily')),
                ButtonSegment(value: _View.weekly, label: Text('Weekly')),
                ButtonSegment(value: _View.monthly, label: Text('Monthly')),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            const SizedBox(height: 14),
            AsyncBody<Json>(value: cf, onRetry: () => ref.invalidate(cashflowProvider), builder: (d) => _body(d, cur)),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }

  Widget _body(Json d, Currency cur) {
    final proj = d['projection'] as Json;
    final summary = proj['summary'] as Json;
    final actual = d['actual_balance'] as Json;
    if (summary['complete'] != true) {
      return EmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Add your cash balance',
        body: (summary['incomplete_reasons'] as List).join(' '),
        action: FilledButton(onPressed: () => context.push('/setup'), child: const Text('Add balance')),
      );
    }
    final events = (d['events'] as List).cast<Json>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: _Stat(label: 'Actual balance', value: actual['amount_minor'] == null ? '—' : cur.format(actual['amount_minor'] as int), sub: 'You reported · ${fmtDate(actual['as_of'] as String?)}', color: C.text)),
        const SizedBox(width: 10),
        Expanded(child: _Stat(label: 'Projected lowest', value: cur.format(summary['lowest_balance_minor'] as int), sub: 'Simulated · ${fmtDate(summary['lowest_balance_date'] as String?)}', color: balanceColor(summary['lowest_balance_minor'] as int))),
      ]),
      const SizedBox(height: 12),
      SectionCard(child: BalanceChart(daily: (proj['daily'] as List).cast<Json>().take(_horizon).toList(), currency: cur)),
      const SectionTitle('Timeline'),
      const Wrap(spacing: 6, runSpacing: 6, children: [StatusChip('actual'), StatusChip('scheduled'), StatusChip('estimated'), StatusChip('hypothetical')]),
      const SizedBox(height: 10),
      if (_view == _View.daily)
        ..._dailyList(events, cur)
      else
        ..._periodList(((_view == _View.weekly ? proj['weekly'] : proj['monthly']) as List).cast<Json>(), cur),
    ]);
  }

  List<Widget> _dailyList(List<Json> events, Currency cur) {
    final shown = events.where((e) => DateTime.parse(e['date'] as String).difference(DateTime.now()).inDays < 30).toList();
    if (shown.isEmpty) return [const EmptyState(icon: Icons.event_busy_outlined, title: 'No events in this window', body: 'Add income and obligations in Records, or tap “Add event”.')];
    final out = <Widget>[];
    String? last;
    for (final e in shown) {
      final date = e['date'] as String;
      if (date != last) {
        out.add(Padding(padding: const EdgeInsets.fromLTRB(2, 14, 0, 6), child: Text(DateFormat('EEE, d MMM').format(DateTime.parse(date)), style: const TextStyle(color: C.muted, fontWeight: FontWeight.w600))));
        last = date;
      }
      final delta = e['delta_minor'] as int;
      final bal = e['balance_after_minor'] as int;
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SectionCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          onTap: () => _eventActions(e, cur),
          child: Row(children: [
            Icon(delta > 0 ? Icons.south_west_rounded : Icons.north_east_rounded, color: delta > 0 ? C.emerald : C.muted, size: 18),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(children: [StatusChip(e['status'] as String), if (e['note'] != null) ...[const SizedBox(width: 6), Flexible(child: Text(e['note'] as String, style: const TextStyle(fontSize: 11, color: C.amber), overflow: TextOverflow.ellipsis))]]),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(cur.format(delta, showSign: true), style: TextStyle(fontWeight: FontWeight.w700, color: delta > 0 ? C.emerald : C.text)),
              Text('bal ${cur.format(bal, compact: true)}', style: TextStyle(fontSize: 11, color: bal < 0 ? C.red : C.muted)),
            ]),
          ]),
        ),
      ));
    }
    return out;
  }

  List<Widget> _periodList(List<Json> rows, Currency cur) => [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SectionCard(
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_view == _View.weekly ? 'Week of ${fmtDate(r['period'] as String)}' : DateFormat('MMMM y').format(DateTime.parse('${r['period']}-01')), style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('In ${cur.format(r['inflow_minor'] as int)}  ·  Out ${cur.format(r['outflow_minor'] as int)}', style: const TextStyle(fontSize: 12, color: C.muted)),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('Closing', style: TextStyle(fontSize: 11, color: C.muted)),
                  Text(r['closing_minor'] == null ? '—' : cur.format(r['closing_minor'] as int), style: TextStyle(fontWeight: FontWeight.w700, color: balanceColor((r['closing_minor'] as int?) ?? 0))),
                ]),
              ]),
            ),
          ),
      ];

  // ---- actions on a timeline row ----
  Future<void> _eventActions(Json e, Currency cur) async {
    final events = ref.read(eventsProvider).valueOrNull ?? const [];
    final id = e['event_id'] as String;
    final manual = events.cast<Json?>().firstWhere((x) => x!['id'] == id, orElse: () => null);
    final recordId = e['source_record_id'] as String;
    final isHypothetical = e['status'] == 'hypothetical';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(e['label'] as String, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('${fmtDate(e['date'] as String, year: true)} · ${cur.format(e['delta_minor'] as int)}')),
          ListTile(
            leading: const Icon(Icons.source_outlined),
            title: const Text('Source'),
            subtitle: Text(manual != null ? 'Added manually as a one-off event' : isHypothetical ? 'Hypothetical (scenario assumption)' : 'From a financial record · tap to open Records'),
            onTap: manual != null || isHypothetical ? null : () {
              Navigator.pop(ctx);
              context.go('/records');
            },
          ),
          if (!isHypothetical) ...[
            ListTile(
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('Edit amount / change date'),
              onTap: () {
                Navigator.pop(ctx);
                _openEventForm(context, ref, cur, existing: e, manual: manual, recordId: recordId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, color: C.emerald),
              title: const Text('Mark as completed'),
              subtitle: const Text('Already paid / received — removes it from the projection'),
              onTap: () {
                Navigator.pop(ctx);
                _complete(e, manual, recordId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: C.red),
              title: Text(manual != null ? 'Delete event' : 'Skip this occurrence'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteOrSkip(e, manual, recordId);
              },
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _withUndo(Future<Json?> Function() action, String message, Future<void> Function(Json? result) undo) async {
    try {
      final r = await action();
      refreshFinancialData(ref);
      if (!mounted) return;
      showSnack(context, message, action: SnackBarAction(label: 'Undo', onPressed: () async {
        try {
          await undo(r);
          refreshFinancialData(ref);
        } catch (e) {
          if (mounted) showSnack(context, errorText(e));
        }
      }));
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Map<String, dynamic> _overrideBody(Json e, String recordId, {bool completed = false, bool skipped = false}) => {
        'label': e['label'], 'kind': e['kind'], 'amount_minor': (e['delta_minor'] as int).abs(), 'date': e['date'],
        'record_id': recordId, 'original_date': (e['event_id'] as String).contains('@') ? (e['event_id'] as String).split('@')[1] : e['date'],
        'completed': completed, 'skipped': skipped,
      };

  Future<void> _complete(Json e, Json? manual, String recordId) {
    final api = ref.read(apiProvider);
    if (manual != null) {
      return _withUndo(() => api.patchEvent(manual['id'] as String, {'completed': true, 'status': 'actual'}), 'Marked completed', (_) async => api.undoEvent(manual['id'] as String));
    }
    return _withUndo(() => api.createEvent(_overrideBody(e, recordId, completed: true)), 'Marked completed', (r) async => api.deleteEvent(r!['id'] as String));
  }

  Future<void> _deleteOrSkip(Json e, Json? manual, String recordId) async {
    final api = ref.read(apiProvider);
    if (manual != null) {
      if (!await confirmDialog(context, title: 'Delete event?', body: 'This removes “${e['label']}” from your projection.')) return;
      return _withUndo(() async {
        await api.deleteEvent(manual['id'] as String);
        return null;
      }, 'Event deleted', (_) async => api.undoEvent(manual['id'] as String));
    }
    return _withUndo(() => api.createEvent(_overrideBody(e, recordId, skipped: true)), 'Occurrence skipped', (r) async => api.deleteEvent(r!['id'] as String));
  }

  Future<void> _openEventForm(BuildContext context, WidgetRef ref, Currency cur, {Json? existing, Json? manual, String? recordId}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _EventForm(cur: cur, existing: existing, manual: manual, recordId: recordId, onSaved: (msg, undo) {
          refreshFinancialData(ref);
          if (mounted) showSnack(this.context, msg, action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: () async {
            try {
              await undo();
              refreshFinancialData(ref);
            } catch (e) {
              if (mounted) showSnack(this.context, errorText(e));
            }
          }));
        }),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub, required this.color});
  final String label, value, sub;
  final Color color;
  @override
  Widget build(BuildContext context) => SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 4),
          FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color))),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: C.muted, fontSize: 11)),
        ]),
      );
}

class _EventForm extends ConsumerStatefulWidget {
  const _EventForm({required this.cur, required this.onSaved, this.existing, this.manual, this.recordId});
  final Currency cur;
  final Json? existing;
  final Json? manual;
  final String? recordId;
  final void Function(String message, Future<void> Function()? undo) onSaved;
  @override
  ConsumerState<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends ConsumerState<_EventForm> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.existing?['label'] as String? ?? '');
  late final _amount = TextEditingController(text: widget.existing == null ? '' : widget.cur.plain((widget.existing!['delta_minor'] as int).abs()));
  late String _kind = widget.existing?['kind'] as String? ?? 'unexpected_expense';
  late String _status = (widget.manual?['status'] ?? 'scheduled') as String;
  late DateTime? _date = widget.existing == null ? null : DateTime.tryParse(widget.existing!['date'] as String);
  bool _busy = false;

  static const kinds = {
    'income': 'Income', 'essential_expense': 'Essential expense', 'discretionary_expense': 'Discretionary expense',
    'loan_repayment': 'Loan repayment', 'credit_card': 'Credit card payment', 'insurance': 'Insurance premium',
    'other_commitment': 'Other commitment', 'unexpected_expense': 'Unexpected expense',
  };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    final amount = widget.cur.parse(_amount.text)!;
    try {
      if (widget.existing == null) {
        final created = await api.createEvent({'label': _label.text.trim(), 'kind': _kind, 'amount_minor': amount, 'date': isoDate(_date!), 'status': _status});
        widget.onSaved('Event added', () async => api.deleteEvent(created['id'] as String));
      } else if (widget.manual != null) {
        final id = widget.manual!['id'] as String;
        await api.patchEvent(id, {'label': _label.text.trim(), 'amount_minor': amount, 'date': isoDate(_date!), 'status': _status});
        widget.onSaved('Event updated', () async => api.undoEvent(id));
      } else {
        final e = widget.existing!;
        final created = await api.createEvent({
          'label': _label.text.trim(), 'kind': e['kind'], 'amount_minor': amount, 'date': isoDate(_date!), 'status': 'estimated',
          'record_id': widget.recordId, 'original_date': (e['event_id'] as String).contains('@') ? (e['event_id'] as String).split('@')[1] : e['date'],
        });
        widget.onSaved('This occurrence was updated', () async => api.deleteEvent(created['id'] as String));
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editingOccurrence = widget.existing != null && widget.manual == null;
    return SafeArea(
      child: Form(
        key: _form,
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text(widget.existing == null ? 'Add a financial event' : 'Edit event', style: Theme.of(context).textTheme.titleMedium),
          if (editingOccurrence) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Changes apply to this occurrence only. Edit the record to change the whole series.', style: TextStyle(color: C.muted, fontSize: 12))),
          const SizedBox(height: 14),
          TextFormField(controller: _label, decoration: const InputDecoration(labelText: 'Description'), validator: (v) => v == null || v.trim().isEmpty ? 'Enter a description' : null),
          if (widget.existing == null) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(initialValue: _kind, decoration: const InputDecoration(labelText: 'Type'), items: [for (final k in kinds.entries) DropdownMenuItem(value: k.key, child: Text(k.value))], onChanged: (v) => setState(() => _kind = v!)),
          ],
          const SizedBox(height: 12),
          MoneyField(controller: _amount, currency: widget.cur),
          const SizedBox(height: 12),
          DateField(value: _date, onChanged: (d) => setState(() => _date = d)),
          if (!editingOccurrence) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Certainty'),
              items: const [
                DropdownMenuItem(value: 'scheduled', child: Text('Scheduled / confirmed')),
                DropdownMenuItem(value: 'estimated', child: Text('Estimated')),
              ],
              onChanged: (v) => setState(() => _status = v!),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton(onPressed: _busy ? null : _save, child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Save')),
        ]),
      ),
    );
  }
}
