import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/auth_repository.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/forms.dart';

enum AuthMode { signin, register, reset }

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.initialMode = AuthMode.signin});
  final AuthMode initialMode;
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  late AuthMode _mode = widget.initialMode;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f, {String? route}) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final boot = ref.read(bootstrappingProvider.notifier);
    if (route != null) boot.state = true; // keep this screen alive until we navigate ourselves
    try {
      await f();
      if (route != null) {
        boot.state = false;
        if (mounted) context.go(route);
      }
    } on AuthException catch (e) {
      boot.state = false;
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final auth = ref.read(authRepositoryProvider);
    switch (_mode) {
      case AuthMode.signin:
        _run(() => auth.signInWithEmail(_email.text, _pass.text), route: '/home');
      case AuthMode.register:
        _run(() => auth.registerWithEmail(_email.text, _pass.text), route: '/setup');
      case AuthMode.reset:
        _run(() async {
          await auth.sendPasswordReset(_email.text);
          if (mounted) setState(() => _info = 'If an account exists for that email, a reset link is on its way.');
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dev = ref.watch(authRepositoryProvider).isLocalDev;
    final title = switch (_mode) { AuthMode.signin => 'Welcome back', AuthMode.register => 'Create your account', AuthMode.reset => 'Reset password' };
    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: () => context.go('/welcome'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            Form(
              key: _form,
              child: Column(children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: validateEmail,
                ),
                if (_mode != AuthMode.reset) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _pass,
                    obscureText: _obscure,
                    autofillHints: [_mode == AuthMode.register ? AutofillHints.newPassword : AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => validatePassword(v, min: _mode == AuthMode.register ? 8 : 6),
                  ),
                ],
                if (_mode == AuthMode.register) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirm,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: 'Confirm password'),
                    validator: (v) => v != _pass.text ? 'Passwords do not match' : null,
                  ),
                ],
              ]),
            ),
            if (_error != null) _Banner(text: _error!, color: C.red),
            if (_info != null) _Banner(text: _info!, color: C.emerald),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : Text(switch (_mode) { AuthMode.signin => 'Sign in', AuthMode.register => 'Create account', AuthMode.reset => 'Send reset link' }),
            ),
            if (_mode != AuthMode.reset && !dev) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(ref.read(authRepositoryProvider).signInWithGoogle, route: '/home'),
                icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                label: const Text('Continue with Google'),
              ),
            ],
            const SizedBox(height: 16),
            if (_mode == AuthMode.signin) TextButton(onPressed: () => setState(() => _mode = AuthMode.reset), child: const Text('Forgot password?')),
            TextButton(
              onPressed: () => setState(() {
                _mode = _mode == AuthMode.register ? AuthMode.signin : AuthMode.register;
                _error = null;
              }),
              child: Text(_mode == AuthMode.register ? 'Already have an account? Sign in' : 'New here? Create an account'),
            ),
            if (_mode == AuthMode.register)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('We will send a verification email. You can use the app while it is pending.', style: TextStyle(color: C.muted, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.5))),
          child: Text(text),
        ),
      );
}
