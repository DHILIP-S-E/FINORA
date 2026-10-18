import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

const recordTypes = {
  'income': ('Income source', Icons.south_west_rounded),
  'recurring_expense': ('Recurring expense', Icons.repeat_rounded),
  'loan': ('Loan', Icons.account_balance_outlined),
  'credit_card': ('Credit card', Icons.credit_card_outlined),
  'insurance': ('Insurance premium', Icons.shield_outlined),
  'one_time_expense': ('One-time expense', Icons.receipt_long_outlined),
  'emergency_savings': ('Emergency savings', Icons.savings_outlined),
  'other': ('Other commitment', Icons.more_horiz_rounded),
};

const frequencies = {'once': 'One time', 'weekly': 'Weekly', 'fortnightly': 'Fortnightly', 'monthly': 'Monthly', 'custom_days': 'Every N days'};

class RecordForm extends ConsumerStatefulWidget {
  const RecordForm({super.key, this.existing, this.prefill, this.onSubmit});
  final Json? existing;
  final Json? prefill;

  /// When set, the validated body is handed to this callback instead of POST /records
  /// (used by the document flow so the record is created through /documents/{id}/confirm).
  final Future<void> Function(Map<String, dynamic> body)? onSubmit;
  @override
  ConsumerState<RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends ConsumerState<RecordForm> {
  final _form = GlobalKey<FormState>();
  late final Json _init = widget.existing ?? widget.prefill ?? {};
  late final Currency _cur = ref.read(currencyProvider);
  late final _name = TextEditingController(text: _init['name'] as String? ?? '');
  late final _amount = TextEditingController(text: _init['amount_minor'] == null ? '' : _cur.plain(_init['amount_minor'] as int));
  late final _category = TextEditingController(text: _init['category'] as String? ?? '');
  late final _notes = TextEditingController(text: _init['notes'] as String? ?? '');
  late final _grace = TextEditingController(text: _init['grace_days']?.toString() ?? '');
  late final _interval = TextEditingController(text: _init['interval_days']?.toString() ?? '');
  late String _type = _init['type'] as String? ?? 'recurring_expense';
  late String _freq = _init['frequency'] as String? ?? 'monthly';
  late DateTime? _start = DateTime.tryParse(_init['start_date'] as String? ?? '');
  late DateTime? _end = DateTime.tryParse(_init['end_date'] as String? ?? '');
  late bool _discretionary = _init['discretionary'] == true;
  late bool _variable = _init['variable_rate'] == true;
  late bool _estimated = _init['estimated'] == true;
  late String _verification = _init['verification'] as String? ?? 'user_provided';
  bool _busy = false;

  bool get _isSavings => _type == 'emergency_savings';
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_name, _amount, _category, _notes, _grace, _interval]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final body = <String, dynamic>{
      'name': _name.text.trim(), 'type': _type, 'amount_minor': _cur.parse(_amount.text), 'currency': _cur.code,
      'category': _category.text.trim().isEmpty ? null : _category.text.trim(),
      'frequency': _isSavings ? 'once' : _freq,
      'start_date': _isSavings || _start == null ? null : isoDate(_start!),
      'end_date': _end == null || _freq == 'once' ? null : isoDate(_end!),
      'interval_days': _freq == 'custom_days' ? int.tryParse(_interval.text) : null,
      'grace_days': _grace.text.trim().isEmpty ? null : int.tryParse(_grace.text),
      'discretionary': _discretionary, 'variable_rate': _type == 'loan' && _variable, 'estimated': _estimated,
      'verification': _verification, 'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    try {
      final api = ref.read(apiProvider);
      if (widget.onSubmit != null) {
        body['source'] = widget.prefill?['source'] ?? 'manual';
        body['source_ref'] = widget.prefill?['source_ref'];
        await widget.onSubmit!(body);
      } else if (_isEdit) {
        // PATCH carries only editable fields (type/currency/source are immutable)
        for (final k in ['type', 'currency']) {
          body.remove(k);
        }
        await api.patchRecord(widget.existing!['id'] as String, body);
      } else {
        await api.createRecord(body);
      }
      refreshFinancialData(ref);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showGrace = _type == 'loan' || _type == 'credit_card' || _type == 'insurance' || _type == 'other';
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit record' : 'New record')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final t in recordTypes.entries) DropdownMenuItem(value: t.key, child: Text(t.value.$1))],
              onChanged: _isEdit ? null : (v) => setState(() => _type = v!),
            ),
            const SizedBox(height: 14),
            TextFormField(controller: _name, maxLength: 120, decoration: const InputDecoration(labelText: 'Name', counterText: ''), validator: (v) => v == null || v.trim().isEmpty ? 'Enter a name' : null),
            const SizedBox(height: 14),
            MoneyField(controller: _amount, currency: _cur, label: _isSavings ? 'Amount saved' : 'Amount per payment', allowZero: _isSavings),
            if (!_isSavings) ...[
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _freq,
                decoration: const InputDecoration(labelText: 'Frequency'),
                items: [for (final f in frequencies.entries) DropdownMenuItem(value: f.key, child: Text(f.value))],
                onChanged: (v) => setState(() => _freq = v!),
              ),
              if (_freq == 'custom_days') ...[
                const SizedBox(height: 14),
                TextFormField(controller: _interval, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Repeat every (days)'), validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return n == null || n < 1 || n > 366 ? 'Enter 1–366' : null;
                }),
              ],
              const SizedBox(height: 14),
              DateField(value: _start, label: _freq == 'once' ? 'Date' : 'First / next date', onChanged: (d) => setState(() => _start = d)),
              if (_freq != 'once') ...[
                const SizedBox(height: 14),
                DateField(value: _end, label: 'Ends (optional)', required: false, onChanged: (d) => setState(() => _end = d)),
              ],
            ],
            const SizedBox(height: 14),
            TextFormField(controller: _category, maxLength: 60, decoration: const InputDecoration(labelText: 'Category (optional)', counterText: '')),
            if (showGrace) ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: _grace,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Grace period in days (optional)', helperText: 'Leave blank if unknown — CASCADE will not assume one'),
                validator: (v) {
                  if (v == null || v.isEmpty) return null;
                  final n = int.tryParse(v);
                  return n == null || n < 0 || n > 60 ? 'Enter 0–60' : null;
                },
              ),
            ],
            if (_type == 'loan') SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Variable interest rate'), subtitle: const Text('Payments may change after a rate reset'), value: _variable, onChanged: (v) => setState(() => _variable = v)),
            if (_type == 'recurring_expense' || _type == 'one_time_expense') SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Discretionary'), subtitle: const Text('Can be reduced if cash gets tight'), value: _discretionary, onChanged: (v) => setState(() => _discretionary = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('This is an estimate'), subtitle: const Text('Amount or timing is uncertain'), value: _estimated, onChanged: (v) => setState(() => _estimated = v)),
            DropdownButtonFormField<String>(
              initialValue: const ['user_provided', 'verified', 'extracted_unverified', 'demo'].contains(_verification) ? _verification : 'user_provided',
              decoration: const InputDecoration(labelText: 'Verification'),
              items: const [
                DropdownMenuItem(value: 'user_provided', child: Text('Entered by me')),
                DropdownMenuItem(value: 'verified', child: Text('Verified against a document')),
                DropdownMenuItem(value: 'extracted_unverified', child: Text('Extracted, not yet verified')),
                DropdownMenuItem(value: 'demo', child: Text('Synthetic demo')),
              ],
              onChanged: (v) => setState(() => _verification = v!),
            ),
            const SizedBox(height: 14),
            TextFormField(controller: _notes, maxLength: 1000, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes (optional)')),
            if (_isEdit) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Source: ${widget.existing!['source'] ?? 'manual'}', style: const TextStyle(color: C.muted, fontSize: 12))),
            const SizedBox(height: 18),
            FilledButton(onPressed: _busy ? null : _save, child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)) : Text(_isEdit ? 'Save changes' : 'Add record')),
          ]),
        ),
      ),
    );
  }
}
