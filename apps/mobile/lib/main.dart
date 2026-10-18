import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'auth/auth_repository.dart';
import 'core/config.dart';
import 'core/providers.dart';

const _googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const cfg = AppConfig.fromEnvironment;

  AuthRepository auth;
  if (cfg.firebaseEnabled) {
    // Requires android/app/google-services.json (see docs/setup.md).
    await Firebase.initializeApp();
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kReleaseMode ? const AndroidPlayIntegrityProvider() : const AndroidDebugProvider(),
    );
    auth = FirebaseAuthRepository(googleServerClientId: _googleServerClientId.isEmpty ? null : _googleServerClientId);
  } else {
    if (kReleaseMode) {
      throw StateError('Release builds must be built with --dart-define=FIREBASE_ENABLED=true');
    }
    auth = DevAuthRepository();
  }

  runApp(ProviderScope(
    overrides: [authRepositoryProvider.overrideWithValue(auth)],
    child: const CascadeApp(),
  ));
}
