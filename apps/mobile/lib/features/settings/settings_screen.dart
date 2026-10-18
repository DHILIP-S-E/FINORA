import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forms.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authStateProvider).valueOrNull;
    final profile = ref.watch(profileProvider).valueOrNull;
    final cur = ref.watch(currencyProvider);
    final isDemo = profile?['is_demo'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & settings')),
      body: SafeArea(
        child: PageList(children: [
          SectionCard(
            child: Row(children: [
              const CircleAvatar(backgroundColor: C.cardHi, child: Icon(Icons.person_outline)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isDemo ? 'Demo user' : user?.email ?? (user?.isAnonymous == true ? 'Guest' : 'Signed in'), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (user?.email != null && user!.emailVerified == false)
                  GestureDetector(
                    onTap: () async {
                      await ref.read(authRepositoryProvider).sendEmailVerification();
                      if (context.mounted) showSnack(context, 'Verification email sent.');
                    },
                    child: const Text('Email not verified · tap to resend', style: TextStyle(color: C.amber, fontSize: 12)),
                  ),
                if (isDemo) const Text('Synthetic data', style: TextStyle(color: C.amber, fontSize: 12)),
              ])),
            ]),
          ),
          const SectionTitle('Money'),
          _Tile(icon: Icons.account_balance_wallet_outlined, title: 'Update cash balance', subtitle: profile?['opening_balance_minor'] == null ? 'Not set' : '${cur.format(profile!['opening_balance_minor'] as int)} · as of ${fmtDate(profile['balance_as_of'] as String?)}', onTap: () => _balanceDialog(context, ref, cur)),
          _Tile(icon: Icons.currency_exchange, title: 'Currency', subtitle: cur.code, onTap: () => _currencyDialog(context, ref, cur)),
          const SectionTitle('Notifications'),
          _Tile(icon: Icons.notifications_outlined, title: 'Notification preferences', subtitle: 'Thresholds, quiet hours, alert types', onTap: () => context.push('/notification-settings')),
          _Tile(icon: Icons.history, title: 'Alert history', onTap: () => context.push('/alerts')),
          const SectionTitle('Your data'),
          _Tile(icon: Icons.document_scanner_outlined, title: 'Uploaded documents', subtitle: 'View or delete uploaded files', onTap: () => context.push('/documents')),
          _Tile(icon: Icons.receipt_long_outlined, title: 'Financial records', subtitle: 'Edit or delete individual records', onTap: () => context.go('/records')),
          _Tile(icon: Icons.download_outlined, title: 'Export my data', subtitle: 'JSON copy of everything we hold', onTap: () => _export(context, ref)),
          if (isDemo) _Tile(icon: Icons.restart_alt, title: 'Reset demo data', subtitle: 'Removes synthetic data and starts a clean profile', onTap: () => _resetDemo(context, ref)),
          const SectionTitle('Privacy & AI'),
          SectionCard(
            child: const Text(
              'AI features (scenario discovery, assistant, document reading, explanations) send a minimised summary of your records '
              '— or a document you choose to upload — to Google Gemini via our server. Your API keys never live on your phone. '
              'AI proposes and explains; all amounts come from a deterministic calculation engine. Without AI configured, CASCADE '
              'falls back to clearly labelled rule-based suggestions and still calculates exactly.\n\n'
              'Uploaded files are private to your account. Push notifications never contain financial amounts.',
              style: TextStyle(color: C.muted, fontSize: 13, height: 1.45),
            ),
          ),
          const SectionTitle('Account'),
          _Tile(icon: Icons.logout, title: 'Sign out', onTap: () async {
            await ref.read(authRepositoryProvider).signOut();
            if (context.mounted) context.go('/welcome');
          }),
          _Tile(icon: Icons.delete_forever_outlined, title: 'Delete account and all data', danger: true, onTap: () => _deleteAccount(context, ref)),
          const DisclaimerFooter(),
        ]),
      ),
    );
  }

  Future<void> _balanceDialog(BuildContext context, WidgetRef ref, Currency cur) async {
    final c = TextEditingController();
    final key = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Current cash balance'),
        content: Form(key: key, child: MoneyField(controller: c, currency: cur, label: 'Balance today', allowZero: true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(88, 44)), onPressed: () => key.currentState!.validate() ? Navigator.pop(context, true) : null, child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final p = Map<String, dynamic>.from(await ref.read(apiProvider).getProfile());
      await ref.read(apiProvider).putProfile({
        'display_name': p['display_name'], 'currency': p['currency'] ?? 'INR', 'opening_balance_minor': cur.parse(c.text),
        'balance_as_of': isoDate(DateTime.now()), 'monthly_essential_minor': p['monthly_essential_minor'],
        'reserve_target_minor': p['reserve_target_minor'], 'onboarding_complete': true,
      });
      refreshFinancialData(ref);
      if (context.mounted) showSnack(context, 'Balance updated');
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _currencyDialog(BuildContext context, WidgetRef ref, Currency cur) async {
    final picked = await showDialog<Currency>(
      context: context,
      builder: (_) => SimpleDialog(title: const Text('Currency'), children: [for (final c in Currency.all) SimpleDialogOption(onPressed: () => Navigator.pop(context, c), child: Text('${c.code} (${c.symbol})'))]),
    );
    if (picked == null || picked.code == cur.code) return;
    if (!context.mounted) return;
    final ok = await confirmDialog(context, title: 'Change currency to ${picked.code}?', body: 'Existing amounts are NOT converted — they keep their numeric value. Update your records if needed.', confirm: 'Change');
    if (!ok) return;
    try {
      final p = Map<String, dynamic>.from(await ref.read(apiProvider).getProfile());
      await ref.read(apiProvider).putProfile({
        'display_name': p['display_name'], 'currency': picked.code, 'opening_balance_minor': p['opening_balance_minor'], 'balance_as_of': p['balance_as_of'],
        'monthly_essential_minor': p['monthly_essential_minor'], 'reserve_target_minor': p['reserve_target_minor'], 'onboarding_complete': p['onboarding_complete'] ?? false,
      });
      refreshFinancialData(ref);
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final data = await ref.read(apiProvider).exportAccount();
      await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)));
      if (context.mounted) showSnack(context, 'Export copied to clipboard (${data.length} sections).');
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _resetDemo(BuildContext context, WidgetRef ref) async {
    if (!await confirmDialog(context, title: 'Reset demo data?', body: 'All synthetic demo data will be removed.', confirm: 'Reset')) return;
    try {
      await ref.read(apiProvider).resetDemo();
      refreshFinancialData(ref);
      if (context.mounted) showSnack(context, 'Demo data removed');
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This permanently deletes your profile, records, scenarios, alerts and uploaded documents. It cannot be undone.'),
            const SizedBox(height: 12),
            TextField(controller: c, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Type DELETE to confirm')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: C.red, foregroundColor: Colors.white, minimumSize: const Size(88, 44)), onPressed: c.text == 'DELETE' ? () => Navigator.pop(ctx, true) : null, child: const Text('Delete everything')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).deleteAccount();
      await ref.read(authRepositoryProvider).signOut();
      if (context.mounted) context.go('/welcome');
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, required this.onTap, this.subtitle, this.danger = false});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SectionCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Icon(icon, color: danger ? C.red : C.muted),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: danger ? C.red : C.text)),
              if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 12, color: C.muted)),
            ])),
            const Icon(Icons.chevron_right, color: C.muted),
          ]),
        ),
      );
}
