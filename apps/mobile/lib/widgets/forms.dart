import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/money.dart';

class MoneyField extends StatelessWidget {
  const MoneyField({super.key, required this.controller, required this.currency, this.label = 'Amount', this.required = true, this.allowZero = false, this.helper});
  final TextEditingController controller;
  final Currency currency;
  final String label;
  final bool required;
  final bool allowZero;
  final String? helper;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        decoration: InputDecoration(labelText: label, prefixText: '${currency.symbol} ', helperText: helper),
        validator: (v) {
          if (v == null || v.trim().isEmpty) return required ? 'Enter an amount' : null;
          final m = currency.parse(v);
          if (m == null) return 'Enter a valid amount (max ${currency.exponent} decimals)';
          if (m < 0) return 'Amount cannot be negative';
          if (m == 0 && !allowZero) return 'Amount must be greater than zero';
          return null;
        },
      );
}

class DateField extends StatelessWidget {
  const DateField({super.key, required this.value, required this.onChanged, this.label = 'Date', this.required = true, this.first, this.last});
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String label;
  final bool required;
  final DateTime? first;
  final DateTime? last;

  @override
  Widget build(BuildContext context) => FormField<DateTime>(
        initialValue: value,
        key: ValueKey(value),
        validator: (_) => required && value == null ? 'Choose a date' : null,
        builder: (state) => InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: value ?? now,
              firstDate: first ?? DateTime(now.year - 2),
              lastDate: last ?? DateTime(now.year + 5),
            );
            if (d != null) onChanged(d);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              errorText: state.errorText,
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                if (value != null && !required) IconButton(tooltip: 'Clear date', icon: const Icon(Icons.clear), onPressed: () => onChanged(null)),
                const Icon(Icons.calendar_today_outlined, size: 18),
                const SizedBox(width: 12),
              ]),
            ),
            child: Text(value == null ? 'Select date' : DateFormat('d MMM y').format(value!)),
          ),
        ),
      );
}

String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

final _emailRx = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');
String? validateEmail(String? v) => v == null || !_emailRx.hasMatch(v.trim()) ? 'Enter a valid email address' : null;
String? validatePassword(String? v, {int min = 8}) => v == null || v.length < min ? 'Use at least $min characters' : null;
