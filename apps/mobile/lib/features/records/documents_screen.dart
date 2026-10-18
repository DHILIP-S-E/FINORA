import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'record_form.dart';

const _maxBytes = 10 * 1024 * 1024;
const _mimeByExt = {'pdf': 'application/pdf', 'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'webp': 'image/webp'};

final documentsProvider = FutureProvider.autoDispose<List<Json>>((ref) => ref.watch(apiProvider).listDocuments());

class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});
  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  bool _busy = false;
  String _step = '';

  Future<void> _pickAndUpload() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _mimeByExt.keys.toList());
    if (f == null || !mounted) return;
    final ext = (f.extension ?? '').toLowerCase();
    if (!_mimeByExt.containsKey(ext)) return showSnack(context, 'Only PDF, PNG, JPEG or WebP files are supported.');
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    if (bytes.length > _maxBytes) return showSnack(context, 'That file is too large. The limit is 10 MB.');
    setState(() {
      _busy = true;
      _step = 'Uploading privately…';
    });
    final api = ref.read(apiProvider);
    try {
      final doc = await api.uploadDocument(bytes, f.name, _mimeByExt[ext]!);
      ref.invalidate(documentsProvider);
      await _extract(doc['id'] as String);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extract(String id) async {
    setState(() {
      _busy = true;
      _step = 'Extracting terms with AI…';
    });
    try {
      final ex = await ref.read(apiProvider).extractDocument(id);
      ref.invalidate(documentsProvider);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExtractionReviewScreen(documentId: id, extraction: ex)));
      ref.invalidate(documentsProvider);
    } on ApiException catch (e) {
      ref.invalidate(documentsProvider);
      if (mounted) showSnack(context, e.isAiUnavailable ? 'Extraction is unavailable right now. Retry later, or add the record manually.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Json d) async {
    if (!await confirmDialog(context, title: 'Delete document?', body: 'The uploaded file and its extracted data will be permanently deleted. Records you already confirmed are kept.')) return;
    try {
      await ref.read(apiProvider).deleteDocument(d['id'] as String);
      ref.invalidate(documentsProvider);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Import documents')),
      body: SafeArea(
        child: PageList(children: [
          SectionCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Loan agreements, card statements, insurance schedules', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                'Your file is stored privately for your account and sent to Google Gemini to read its terms. '
                'Nothing becomes a record until you review and confirm it. Missing details stay “unknown” — CASCADE never guesses them.',
                style: TextStyle(color: C.muted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _busy ? null : _pickAndUpload,
                icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file_rounded),
                label: Text(_busy ? _step : 'Choose PDF or image'),
              ),
            ]),
          ),
          const SectionTitle('Uploaded'),
          AsyncBody<List<Json>>(
            value: docs,
            onRetry: () => ref.invalidate(documentsProvider),
            skeletonHeight: 64,
            builder: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.description_outlined, title: 'No documents', body: 'Uploads appear here with their processing status.')
                : Column(children: [
                    for (final d in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SectionCard(
                          child: Row(children: [
                            const Icon(Icons.description_outlined, color: C.blue),
                            const SizedBox(width: 12),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(d['filename'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('${d['status']} · ${(d['size'] as int) ~/ 1024} KB', style: const TextStyle(color: C.muted, fontSize: 12)),
                            ])),
                            if (d['status'] == 'uploaded' || d['status'] == 'failed' || d['status'] == 'extracted')
                              IconButton(tooltip: d['status'] == 'extracted' ? 'Review extraction' : 'Retry extraction', icon: Icon(d['status'] == 'extracted' ? Icons.rate_review_outlined : Icons.refresh), onPressed: _busy ? null : () => _extract(d['id'] as String)),
                            IconButton(tooltip: 'Delete document', icon: const Icon(Icons.delete_outline, color: C.red), onPressed: () => _delete(d)),
                          ]),
                        ),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

/// Review step: every extracted term is shown with its source excerpt, unknowns are flagged, and the user
/// supplies/edits values before anything is committed as a record.
class ExtractionReviewScreen extends ConsumerWidget {
  const ExtractionReviewScreen({super.key, required this.documentId, required this.extraction});
  final String documentId;
  final Json extraction;

  static const _labels = {
    'principal_amount': 'Principal', 'interest_rate_pct': 'Interest rate (%)', 'rate_type': 'Rate type', 'repayment_frequency': 'Repayment frequency',
    'payment_amount': 'Payment / EMI', 'first_payment_date': 'First payment date', 'tenure_months': 'Tenure (months)', 'processing_fee': 'Processing fee',
    'late_payment_penalty': 'Late payment penalty', 'grace_period_days': 'Grace period (days)', 'insurance_premium': 'Insurance premium',
    'premium_due_date': 'Premium due date', 'rate_reset_condition': 'Rate reset condition', 'other_payment_date': 'Other payment date',
  };

  Json _prefill(Currency cur) {
    final terms = {for (final t in (extraction['terms'] as List).cast<Json>()) t['field_name'] as String: t};
    String? v(String k) => terms[k]?['status'] == 'found' ? terms[k]!['value'] as String? : null;
    final type = switch (extraction['document_type']) { 'loan' => 'loan', 'credit_card' => 'credit_card', 'insurance' => 'insurance', _ => 'other' };
    final amountStr = v(type == 'insurance' ? 'insurance_premium' : 'payment_amount') ?? v('payment_amount');
    final minor = amountStr == null ? null : cur.parse(amountStr.replaceAll(RegExp(r'[^0-9.,]'), ''));
    final freqRaw = (v('repayment_frequency') ?? '').toLowerCase();
    final freq = freqRaw.contains('week') ? 'weekly' : freqRaw.contains('fort') ? 'fortnightly' : freqRaw.contains('once') ? 'once' : 'monthly';
    final dateStr = v(type == 'insurance' ? 'premium_due_date' : 'first_payment_date') ?? v('other_payment_date');
    final first = terms.values.firstWhere((t) => t['status'] == 'found' && t['excerpt'] != null, orElse: () => {});
    return {
      'name': '', 'type': type, 'amount_minor': minor, 'frequency': freq, 'start_date': _parseDate(dateStr),
      'grace_days': int.tryParse((v('grace_period_days') ?? '').replaceAll(RegExp(r'[^0-9]'), '')),
      'variable_rate': (v('rate_type') ?? '').toLowerCase().contains(RegExp('variable|floating')),
      'verification': 'extracted_unverified', 'source': 'document',
      'source_ref': first.isEmpty ? null : {'page': first['page'], 'excerpt': first['excerpt']},
    };
  }

  static String? _parseDate(String? s) {
    if (s == null) return null;
    final iso = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
    if (iso != null) return '${iso[1]}-${iso[2]!.padLeft(2, '0')}-${iso[3]!.padLeft(2, '0')}';
    final dmy = RegExp(r'(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})').firstMatch(s);
    if (dmy != null) return '${dmy[3]}-${dmy[2]!.padLeft(2, '0')}-${dmy[1]!.padLeft(2, '0')}';
    return null; // anything else must be chosen by the user
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terms = (extraction['terms'] as List).cast<Json>();
    final conflicts = (extraction['conflicts'] as List).cast<String>();
    final missing = (extraction['missing_information'] as List).cast<String>();
    final live = extraction['live_ai'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Review extracted terms')),
      body: SafeArea(
        child: PageList(children: [
          Wrap(spacing: 6, children: [if (live) const ProvenanceBadge(Provenance.aiHypothesis), const ProvenanceBadge(Provenance.unverified)]),
          const SizedBox(height: 8),
          const Text('Check each value against your document. Nothing is saved until you continue.', style: TextStyle(color: C.muted)),
          if (extraction['suspected_prompt_injection'] == true)
            Container(
              margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.red.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.red.withValues(alpha: 0.5))),
              child: const Text('This document contains text that looks like instructions to an AI. It was treated as data only. Review values with extra care.'),
            ),
          const SectionTitle('Extracted terms'),
          for (final t in terms)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SectionCard(
                borderColor: (t['needs_user_input'] == true) ? C.amber.withValues(alpha: 0.6) : C.line,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(_labels[t['field_name']] ?? t['field_name'] as String, style: const TextStyle(color: C.muted, fontSize: 12))),
                    if (t['status'] == 'unknown') const Text('Not found', style: TextStyle(color: C.amber, fontSize: 12, fontWeight: FontWeight.w700)),
                    if (t['status'] == 'conflict') const Text('Conflict', style: TextStyle(color: C.red, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 2),
                  Text(t['value'] as String? ?? 'Unknown — you will be asked to provide this', style: TextStyle(fontWeight: FontWeight.w600, color: t['value'] == null ? C.amber : C.text)),
                  if (t['excerpt'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('“${t['excerpt']}”${t['page'] != null ? ' — page ${t['page']}' : ''}', style: const TextStyle(fontSize: 12, color: C.muted, fontStyle: FontStyle.italic))),
                  for (final i in (t['validation_issues'] as List).cast<String>()) Padding(padding: const EdgeInsets.only(top: 4), child: Text('⚠ $i', style: const TextStyle(color: C.amber, fontSize: 12))),
                ]),
              ),
            ),
          if (conflicts.isNotEmpty) ...[const SectionTitle('Conflicts'), for (final c in conflicts) Text('• $c')],
          if (missing.isNotEmpty) ...[const SectionTitle('Still needed'), for (final c in missing) Text('• $c')],
          const SizedBox(height: 20),
          FilledButton.icon(
            icon: const Icon(Icons.edit_note),
            label: const Text('Review & create record'),
            onPressed: () async {
              final prefill = _prefill(ref.read(currencyProvider));
              prefill['name'] = (extraction['document_type'] as String).replaceAll('_', ' ');
              final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
                builder: (_) => RecordForm(
                  prefill: prefill,
                  onSubmit: (body) async {
                    await ref.read(apiProvider).confirmDocument(documentId, [body]);
                    refreshFinancialData(ref);
                  },
                ),
              ));
              if (saved == true && context.mounted) Navigator.pop(context);
            },
          ),
        ]),
      ),
    );
  }
}
