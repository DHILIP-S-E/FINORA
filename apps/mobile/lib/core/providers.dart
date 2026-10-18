import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_repository.dart';
import 'api.dart';
import 'config.dart';
import 'money.dart';

final configProvider = Provider<AppConfig>((_) => AppConfig.fromEnvironment);

/// Overridden in main() with the Firebase or local-dev implementation (and with fakes in tests).
final authRepositoryProvider = Provider<AuthRepository>((_) => throw UnimplementedError('authRepositoryProvider not overridden'));

final authStateProvider = StreamProvider<AuthUser?>((ref) => ref.watch(authRepositoryProvider).authStateChanges());

/// Set while a flow (demo start, registration) is mid-way, so the auth redirect does not yank the user away.
final bootstrappingProvider = StateProvider<bool>((_) => false);

final apiProvider = Provider<CascadeApi>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  final cfg = ref.watch(configProvider);
  return HttpCascadeApi(
    baseUrl: cfg.apiBaseUrl,
    token: auth.idToken,
    extraHeaders: cfg.firebaseEnabled
        ? () async {
            try {
              final t = await FirebaseAppCheck.instance.getToken();
              return t == null ? const {} : {'X-Firebase-AppCheck': t};
            } catch (_) {
              return const {};
            }
          }
        : null,
  );
});

final profileProvider = FutureProvider.autoDispose<Json>((ref) {
  ref.watch(authStateProvider); // refetch when the user changes
  return ref.watch(apiProvider).getProfile();
});

final currencyProvider = Provider.autoDispose<Currency>((ref) =>
    Currency.of(ref.watch(profileProvider).valueOrNull?['currency'] as String?));

final cashflowProvider = FutureProvider.autoDispose.family<Json, int>((ref, horizon) {
  ref.watch(authStateProvider);
  return ref.watch(apiProvider).getCashflow(horizonDays: horizon);
});

final recordsProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(apiProvider).listRecords();
});

final scenariosProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(apiProvider).listScenarios();
});

final alertsProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(apiProvider).listAlerts();
});

final eventsProvider = FutureProvider.autoDispose<List<Json>>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(apiProvider).listEvents();
});

/// Invalidate everything that depends on the user's financial data (after any write).
void refreshFinancialData(WidgetRef ref) {
  ref.invalidate(profileProvider);
  ref.invalidate(cashflowProvider);
  ref.invalidate(recordsProvider);
  ref.invalidate(scenariosProvider);
  ref.invalidate(alertsProvider);
  ref.invalidate(eventsProvider);
}
