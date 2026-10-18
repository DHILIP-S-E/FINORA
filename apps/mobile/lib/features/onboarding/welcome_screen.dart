import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});
  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool _demoLoading = false;

  Future<void> _startDemo() async {
    setState(() => _demoLoading = true);
    final boot = ref.read(bootstrappingProvider.notifier);
    boot.state = true; // hold the auth redirect until the demo data exists
    try {
      await ref.read(authRepositoryProvider).signInAnonymously();
      await ref.read(apiProvider).seedDemo();
      refreshFinancialData(ref);
      boot.state = false;
      if (mounted) context.go('/home');
    } catch (e) {
      boot.state = false;
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _demoLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dev = ref.watch(authRepositoryProvider).isLocalDev;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: C.emerald.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.stacked_line_chart_rounded, color: C.emerald),
              ),
              const SizedBox(width: 12),
              Text('CASCADE', style: Theme.of(context).textTheme.titleLarge?.copyWith(letterSpacing: 3, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 36),
            Text('See the financial risks\nbefore they happen.', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(height: 14),
            const Text(
              'A late payment, an unexpected bill and a loan EMI can collide. CASCADE finds combinations like these in your own '
              'schedule, simulates them with exact arithmetic, and shows what could help.',
              style: TextStyle(color: C.muted, height: 1.45),
            ),
            const SizedBox(height: 24),
            const _Point(icon: Icons.account_tree_outlined, title: 'Finds compound risks', body: 'AI proposes what-if scenarios you did not think to ask about.'),
            const _Point(icon: Icons.calculate_outlined, title: 'Numbers you can trace', body: 'Every amount comes from a deterministic calculation, never from the AI.'),
            const _Point(icon: Icons.tune_rounded, title: 'Explore alternatives', body: 'Compare baseline, risk and your own changes side by side.'),
            const SizedBox(height: 16),
            SectionCard(
              borderColor: C.line,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [const Icon(Icons.lock_outline, size: 18, color: C.emerald), const SizedBox(width: 8), Text('Your data, explained', style: Theme.of(context).textTheme.titleSmall)]),
                const SizedBox(height: 8),
                const Text(
                  '• We ask for balances, income and obligations only to project your cash flow.\n'
                  '• Data is private to your account. We never connect to your bank.\n'
                  '• AI features send a minimal summary of your records (and any document you choose to upload) to Google Gemini. '
                  'Nothing is sent until you use an AI feature.\n'
                  '• You can export or delete everything at any time in Settings.',
                  style: TextStyle(color: C.muted, height: 1.5, fontSize: 13),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => context.go('/auth?mode=register'), child: const Text('Create account')),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: () => context.go('/auth?mode=signin'), child: const Text('Sign in')),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _demoLoading ? null : _startDemo,
              icon: _demoLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.science_outlined),
              label: const Text('Explore a demo with synthetic data'),
            ),
            if (dev)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Local development mode: Firebase is not configured.', textAlign: TextAlign.center, style: TextStyle(color: C.amber, fontSize: 12)),
              ),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: C.emerald, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(body, style: const TextStyle(color: C.muted, fontSize: 13)),
          ])),
        ]),
      );
}
