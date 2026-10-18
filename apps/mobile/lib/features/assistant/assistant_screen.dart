import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'assistant_widgets.dart';

class _Msg {
  _Msg.user(this.text) : response = null, error = null;
  _Msg.bot(this.response) : text = null, error = null;
  _Msg.err(this.error) : text = null, response = null;
  final String? text;
  final Json? response;
  final String? error;
}

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});
  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  bool _busy = false;

  static const _suggestions = [
    'Why could my balance become negative?',
    'What happens if my payment arrives 10 days late?',
    'Which obligations create the greatest pressure?',
    'Which assumptions have the biggest impact?',
    'What information do you still need?',
  ];

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty || _busy) return;
    _c.clear();
    setState(() {
      _msgs.add(_Msg.user(text));
      _busy = true;
    });
    try {
      final r = await ref.read(apiProvider).assistant(text);
      _msgs.add(_Msg.bot(r));
    } on ApiException catch (e) {
      _msgs.add(_Msg.err(e.isAiUnavailable ? '${e.message}\n\nYou can still use Cash flow and manual what-ifs.' : e.message));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Assistant')),
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: _msgs.isEmpty
                  ? ListView(padding: const EdgeInsets.all(20), children: [
                      const Text('Ask about your cash flow', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      const Text('Answers use your records and the calculation engine. The assistant will say what it can\'t know and won\'t invent missing details.', style: TextStyle(color: C.muted)),
                      const SizedBox(height: 16),
                      for (final s in _suggestions) Padding(padding: const EdgeInsets.only(bottom: 8), child: ActionChip(label: Text(s), onPressed: () => _send(s))),
                    ])
                  : ListView(controller: _scroll, padding: const EdgeInsets.all(16), children: [
                      for (final m in _msgs) _bubble(m),
                      if (_busy) const Padding(padding: EdgeInsets.all(8), child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
                    ]),
            ),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Informational only — not financial advice.', style: TextStyle(fontSize: 11, color: C.muted))),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _c,
                maxLength: 600,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                decoration: InputDecoration(
                  hintText: 'Ask a question or describe a what-if',
                  counterText: '',
                  suffixIcon: IconButton(tooltip: 'Send', icon: const Icon(Icons.arrow_upward_rounded, color: C.emerald), onPressed: _busy ? null : () => _send(_c.text)),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _bubble(_Msg m) {
    if (m.text != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.emerald.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
          child: Text(m.text!),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 16),
      child: SectionCard(
        borderColor: m.error != null ? C.amber.withValues(alpha: 0.5) : C.line,
        child: m.error != null ? Text(m.error!) : AssistantResponseView(response: m.response!),
      ),
    );
  }
}
