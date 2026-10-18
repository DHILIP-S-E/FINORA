import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/push.dart';
import 'core/theme.dart';
import 'router.dart';

class CascadeApp extends ConsumerStatefulWidget {
  const CascadeApp({super.key});
  @override
  ConsumerState<CascadeApp> createState() => _CascadeAppState();
}

class _CascadeAppState extends ConsumerState<CascadeApp> {
  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // Start push registration once a real (Firebase) user is signed in.
    ref.listen(authStateProvider, (_, next) {
      final user = next.valueOrNull;
      if (user != null && !ref.read(authRepositoryProvider).isLocalDev) {
        PushService(ref.read(apiProvider), router).start();
      }
    });
    return MaterialApp.router(
      title: 'CASCADE',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      themeMode: ThemeMode.dark,
      darkTheme: buildTheme(),
      routerConfig: router,
    );
  }
}
