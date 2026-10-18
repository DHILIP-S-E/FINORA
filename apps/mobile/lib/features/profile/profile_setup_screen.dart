import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

/// Collects the minimum needed for a projection. Every field is optional and can be completed later.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _form = GlobalKey<FormState>();
  Currency _cur = Currency.inr;
  final _balance = TextEditingController();
  final _essentials = TextEditingController();
  final _reserve = TextEditingController();
  final _incomeName = TextEditingController();
  final _incomeAmt = TextEditingController();
  String _freq = 'monthly';
  DateTime? _nextIncome;
  bool _estimated = true;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_balance, _essentials, _reserve, _incomeName, _incomeAmt]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final hasIncome = _incomeAmt.text.trim().isNotEmpty;
    if (hasIncome && _nextIncome == null) {
      showSnack(context, 'Choose when this income is next expected.');
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    try {
      int? m(TextEditingController c) => c.text.trim().isEmpty ? null : _cur.parse(c.text);
      await api.putProfile({
        'currency': _cur.code,
        'opening_balance_minor': m(_balance),
        'monthly_essential_minor': m(_essentials),
        'reserve_target_minor': m(_reserve),
        'onboarding_complete': true,
      });
      final now = DateTime.now();
      if (m(_essentials) != null && m(_essentials)! > 0) {
        await api.createRecord({
          'name': 'Monthly essentials', 'type': 'recurring_expense', 'amount_minor': m(_essentials), 'currency': _cur.code,
          'frequency': 'monthly', 'start_date': isoDate(DateTime(now.year, now.month + 1, 1)), 'category': 'essentials', 'estimated': true,
        });
      }
      if (hasIncome) {
        await api.createRecord({
          'name': _incomeName.text.trim().isEmpty ? 'Expected income' : _incomeName.text.trim(),
          'type': 'income', 'amount_minor': m(_incomeAmt), 'currency': _cur.code, 'frequency': _freq,
          'start_date': isoDate(_nextIncome!), 'estimated': _estimated,
        });
      }
      refreshFinancialData(ref);
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Set up your profile'), actions: [TextButton(onPressed: () => context.go('/home'), child: const Text('Skip for now'))]),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 32), children: [
              const Text(
                'Only what is needed to project your cash flow. Everything is optional; you can add or change it later.',
                style: TextStyle(color: C.muted),
              ),
              const SectionTitle('Basics'),
              DropdownButtonFormField<Currency>(
                initialValue: _cur,
                decoration: const InputDecoration(labelText: 'Currency'),
                items: [for (final c in Currency.all) DropdownMenuItem(value: c, child: Text('${c.code} (${c.symbol})'))],
                onChanged: (c) => setState(() => _cur = c ?? Currency.inr),
              ),
              const SizedBox(height: 14),
              MoneyField(controller: _balance, currency: _cur, label: 'Available cash balance today', required: false, allowZero: true, helper: 'Needed to calculate a projection'),
              const SizedBox(height: 14),
              MoneyField(controller: _essentials, currency: _cur, label: 'Monthly essential expenses', required: false, helper: 'Rent, groceries, utilities…'),
              const SizedBox(height: 14),
              MoneyField(controller: _reserve, currency: _cur, label: 'Emergency reserve target', required: false),
              const SectionTitle('An expected income (optional)'),
              TextFormField(controller: _incomeName, decoration: const InputDecoration(labelText: 'Source, e.g. "Client A"')),
              const SizedBox(height: 14),
              MoneyField(controller: _incomeAmt, currency: _cur, label: 'Amount', required: false),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _freq,
                decoration: const InputDecoration(labelText: 'How often'),
                items: const [
                  DropdownMenuItem(value: 'once', child: Text('One time')),
                  DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                  DropdownMenuItem(value: 'fortnightly', child: Text('Fortnightly')),
                  DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                ],
                onChanged: (v) => setState(() => _freq = v ?? 'monthly'),
              ),
              const SizedBox(height: 14),
              DateField(value: _nextIncome, onChanged: (d) => setState(() => _nextIncome = d), label: 'Next expected date', required: false),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Amount or timing may vary'),
                subtitle: const Text('Irregular income is marked as an estimate'),
                value: _estimated,
                onChanged: (v) => setState(() => _estimated = v),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _save, child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Save and continue')),
              const SizedBox(height: 8),
              const Text('You can add loans, cards, insurance and documents from the Records tab.', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        ),
      );
}
