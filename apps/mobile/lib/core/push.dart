import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:go_router/go_router.dart';

import 'api.dart';

/// Registers the FCM token with the backend and routes notification taps to the relevant screen.
/// Payloads carry ids only (no amounts); the destination screen loads details from the API.
class PushService {
  PushService(this._api, this._router);
  final CascadeApi _api;
  final GoRouter _router;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final token = await fm.getToken();
      if (token != null) await _register(token);
      fm.onTokenRefresh.listen(_register);
      FirebaseMessaging.onMessageOpenedApp.listen(_open);
      final initial = await fm.getInitialMessage();
      if (initial != null) _open(initial);
    } catch (_) {
      // Push is optional; the in-app alert history always works.
    }
  }

  Future<void> _register(String token) async {
    try {
      final p = await _api.getPrefs();
      await _api.putPrefs({
        'push_enabled': p['push_enabled'] ?? true, 'min_shortfall_minor': p['min_shortfall_minor'] ?? 0, 'quiet_hours': p['quiet_hours'],
        'utc_offset_minutes': DateTime.now().timeZoneOffset.inMinutes, 'fcm_token': token, 'alert_types': p['alert_types'],
      });
    } catch (_) {}
  }

  void _open(RemoteMessage m) {
    final sid = m.data['scenario_id'];
    _router.go(sid != null ? '/scenarios/$sid' : '/alerts');
  }
}
