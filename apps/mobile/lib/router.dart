import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/assistant/assistant_screen.dart';
import 'features/auth/auth_screen.dart';
import 'features/cashflow/cashflow_screen.dart';
import 'features/home/home_screen.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/profile/profile_setup_screen.dart';
import 'features/records/documents_screen.dart';
import 'features/records/records_screen.dart';
import 'features/scenarios/scenario_detail_screen.dart';
import 'features/scenarios/scenarios_screen.dart';
import 'features/settings/settings_screen.dart';

const _publicPaths = {'/welcome', '/auth'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authStateProvider, (_, __) => refresh.value++);
  ref.listen(bootstrappingProvider, (_, __) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      if (ref.read(bootstrappingProvider)) return null;
      final auth = ref.read(authStateProvider);
      final loc = state.uri.path;
      if (auth.isLoading) return loc == '/splash' ? null : '/splash';
      final signedIn = auth.valueOrNull != null;
      if (!signedIn) return _publicPaths.contains(loc) ? null : '/welcome';
      if (_publicPaths.contains(loc) || loc == '/splash') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const _Splash()),
      GoRoute(path: '/welcome', builder: (_, __) => const WelcomeScreen()),
      GoRoute(
        path: '/auth',
        builder: (_, s) => AuthScreen(
          initialMode: switch (s.uri.queryParameters['mode']) { 'register' => AuthMode.register, 'reset' => AuthMode.reset, _ => AuthMode.signin },
        ),
      ),
      GoRoute(path: '/setup', builder: (_, __) => const ProfileSetupScreen()),
      GoRoute(path: '/assistant', builder: (_, __) => const AssistantScreen()),
      GoRoute(path: '/alerts', builder: (_, __) => const AlertsScreen()),
      GoRoute(path: '/notification-settings', builder: (_, __) => const NotificationSettingsScreen()),
      GoRoute(path: '/documents', builder: (_, __) => const DocumentsScreen()),
      GoRoute(path: '/scenarios/:id', builder: (_, s) => ScenarioDetailScreen(id: s.pathParameters['id']!)),
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => _Shell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, __) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/cashflow', builder: (_, __) => const CashflowScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/scenarios', builder: (_, __) => const ScenariosScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/records', builder: (_, __) => const RecordsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, __) => const SettingsScreen())]),
        ],
      ),
    ],
  );
});

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.timeline_outlined), selectedIcon: Icon(Icons.timeline), label: 'Cash flow'),
            NavigationDestination(icon: Icon(Icons.account_tree_outlined), selectedIcon: Icon(Icons.account_tree), label: 'Scenarios'),
            NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Records'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      );
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.stacked_line_chart_rounded, size: 48, color: C.emerald),
            SizedBox(height: 16),
            Text('CASCADE', style: TextStyle(letterSpacing: 4, fontSize: 20, fontWeight: FontWeight.w700)),
            SizedBox(height: 24),
            SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
        ),
      );
}
