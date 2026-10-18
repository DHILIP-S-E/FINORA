import 'package:cascade/app.dart';
import 'package:cascade/auth/auth_repository.dart';
import 'package:cascade/core/providers.dart';
import 'package:cascade/features/auth/auth_screen.dart';
import 'package:cascade/features/onboarding/welcome_screen.dart';
import 'package:cascade/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fakes.dart';

Future<void> pumpApp(WidgetTester t, {FakeAuthRepository? auth, FakeApi? api}) async {
  t.view.physicalSize = const Size(900, 2200);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth ?? FakeAuthRepository()),
      apiProvider.overrideWithValue(api ?? FakeApi()),
    ],
    child: const CascadeApp(),
  ));
  await t.pumpAndSettle();
}

Widget wrap(Widget child, {FakeAuthRepository? auth, FakeApi? api}) => ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth ?? FakeAuthRepository()),
        apiProvider.overrideWithValue(api ?? FakeApi()),
      ],
      child: MaterialApp(theme: buildTheme(), home: child),
    );

void main() {
  group('Onboarding & auth-state routing', () {
    testWidgets('signed-out users are sent to onboarding with privacy info, disclaimer and demo option', (t) async {
      await pumpApp(t);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.textContaining('Explore a demo'), findsOneWidget);
      expect(find.text('Your data, explained'), findsOneWidget);
      await t.scrollUntilVisible(find.textContaining('not a financial adviser'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('not a financial adviser'), findsOneWidget);
    });

    testWidgets('protected routes redirect to welcome when signed out', (t) async {
      await pumpApp(t);
      final ctx = t.element(find.byType(WelcomeScreen));
      GoRouter.of(ctx).go('/records');
      await t.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('restored session lands on Home (not onboarding)', (t) async {
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', email: 'a@b.co', emailVerified: true)));
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(find.text('Available cash'), findsOneWidget);
      expect(find.text('₹42,000.00'), findsOneWidget);
    });

    testWidgets('demo button signs in anonymously, seeds synthetic data and opens Home', (t) async {
      final auth = FakeAuthRepository();
      final api = FakeApi();
      await pumpApp(t, auth: auth, api: api);
      await t.tap(find.textContaining('Explore a demo'));
      await t.pumpAndSettle();
      expect(auth.calls, contains('anon'));
      expect(api.calls, contains('seedDemo'));
      expect(find.textContaining('Demo mode'), findsOneWidget);
    });

    testWidgets('sign out returns to onboarding', (t) async {
      final auth = FakeAuthRepository(initial: const AuthUser(uid: 'u1', email: 'a@b.co', emailVerified: true));
      await pumpApp(t, auth: auth);
      await t.tap(find.text('Profile'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('Sign out'), 300, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('Sign out'));
      await t.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });
  });

  group('AuthScreen forms', () {
    testWidgets('sign-in validates email and password before calling Firebase', (t) async {
      final auth = FakeAuthRepository();
      await t.pumpWidget(wrap(const AuthScreen(), auth: auth));
      await t.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await t.pump();
      expect(find.text('Enter a valid email address'), findsOneWidget);
      expect(find.textContaining('at least 6'), findsOneWidget);
      expect(auth.calls, isEmpty);
    });

    testWidgets('register requires 8+ chars and matching confirmation', (t) async {
      final auth = FakeAuthRepository();
      await t.pumpWidget(wrap(const AuthScreen(initialMode: AuthMode.register), auth: auth));
      await t.enterText(find.widgetWithText(TextFormField, 'Email'), 'a@b.co');
      await t.enterText(find.widgetWithText(TextFormField, 'Password'), 'short');
      await t.enterText(find.widgetWithText(TextFormField, 'Confirm password'), 'different');
      await t.tap(find.widgetWithText(FilledButton, 'Create account'));
      await t.pump();
      expect(find.textContaining('at least 8'), findsOneWidget);
      expect(find.text('Passwords do not match'), findsOneWidget);
      expect(auth.calls, isEmpty);
    });

    testWidgets('shows a friendly error when authentication fails', (t) async {
      final auth = FakeAuthRepository(failWith: 'Incorrect email or password.');
      await t.pumpWidget(wrap(const AuthScreen(), auth: auth));
      await t.enterText(find.widgetWithText(TextFormField, 'Email'), 'a@b.co');
      await t.enterText(find.widgetWithText(TextFormField, 'Password'), 'wrongpass');
      await t.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await t.pumpAndSettle();
      expect(find.text('Incorrect email or password.'), findsOneWidget);
    });

    testWidgets('password reset mode sends a reset and never reveals whether the account exists', (t) async {
      final auth = FakeAuthRepository();
      await t.pumpWidget(wrap(const AuthScreen(initialMode: AuthMode.reset), auth: auth));
      await t.enterText(find.widgetWithText(TextFormField, 'Email'), 'a@b.co');
      await t.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await t.pumpAndSettle();
      expect(auth.calls, contains('reset:a@b.co'));
      expect(find.textContaining('If an account exists'), findsOneWidget);
    });
  });

  group('Navigation', () {
    testWidgets('bottom navigation reaches all five destinations', (t) async {
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', emailVerified: true)));
      for (final (label, title) in [('Cash flow', 'Cash flow'), ('Scenarios', 'Discover compound risks'), ('Records', 'Financial records'), ('Profile', 'Profile & settings'), ('Home', 'Available cash')]) {
        await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        await t.pumpAndSettle();
        expect(find.text(title), findsWidgets, reason: label);
      }
    });
  });

  group('Primary scenario workflow (UI -> API contract)', () {
    testWidgets('natural-language what-if -> labelled response -> explicit confirm -> saved scenario -> detail with comparison', (t) async {
      final api = FakeApi();
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', emailVerified: true)), api: api);
      await t.scrollUntilVisible(find.text('Explore a scenario'), 400, scrollable: find.byType(Scrollable).first);
      await t.enterText(find.byType(TextField).first, 'My client may pay me 10 days late');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
      expect(api.calls.any((c) => c.startsWith('assistant:')), true);
      // clearly labelled: not live AI, simulated, nothing saved yet
      expect(find.textContaining('Rule-based demo fallback'), findsOneWidget);
      expect(find.text('Simulated result'), findsOneWidget);
      expect(find.text('Nothing is saved until you confirm.'), findsOneWidget);
      expect(api.saved, isEmpty);
      await t.tap(find.text('Confirm & save this scenario'));
      await t.pumpAndSettle();
      expect(api.saved.length, 1);
      expect(api.saved.single['origin'], 'natural_language');
      // detail screen shows baseline vs scenario numbers and the shortfall
      expect(find.text('Baseline vs this scenario'), findsOneWidget);
      expect(find.textContaining('-₹24,400.00'), findsWidgets);
      expect(find.text('Obligations at risk'), findsOneWidget);
      expect(find.textContaining('Reproducible'), findsOneWidget);
      expect(find.textContaining('hypothetical, not a forecast'), findsOneWidget);
    });

    testWidgets('scenario discovery shows rule-based label when no live AI and lets the user save', (t) async {
      final api = FakeApi();
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', emailVerified: true)), api: api);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Scenarios')));
      await t.pumpAndSettle();
      await t.tap(find.text('Find risks'));
      await t.pumpAndSettle();
      expect(find.text('Late payment from Client A'), findsOneWidget);
      expect(find.textContaining('not live AI'), findsWidgets);
      expect(find.textContaining('not a probability'), findsOneWidget);
    });
  });

  group('Empty & error states', () {
    testWidgets('cash flow without a balance asks for it instead of inventing numbers', (t) async {
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', emailVerified: true)), api: FakeApi(withBalance: false));
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Cash flow')));
      await t.pumpAndSettle();
      expect(find.text('Add your cash balance'), findsOneWidget);
    });

    testWidgets('records screen empty state', (t) async {
      await pumpApp(t, auth: FakeAuthRepository(initial: const AuthUser(uid: 'u1', emailVerified: true)));
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Records')));
      await t.pumpAndSettle();
      expect(find.text('No records yet'), findsOneWidget);
    });
  });
}
