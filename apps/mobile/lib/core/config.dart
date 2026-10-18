/// Build-time configuration, supplied with --dart-define (see docs/setup.md).
class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.firebaseEnabled});

  /// Backend base URL. Android emulator -> host machine is 10.0.2.2.
  final String apiBaseUrl;

  /// When false the app runs in LOCAL DEV mode: no Firebase, the API must run with AUTH_MODE=dev.
  /// Never ship a release build with this false.
  final bool firebaseEnabled;

  static const fromEnvironment = AppConfig(
    apiBaseUrl: String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000'),
    firebaseEnabled: bool.fromEnvironment('FIREBASE_ENABLED', defaultValue: false),
  );
}
