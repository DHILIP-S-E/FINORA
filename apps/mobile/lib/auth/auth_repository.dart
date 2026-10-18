import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthUser {
  const AuthUser({required this.uid, this.email, this.emailVerified = false, this.isAnonymous = false});
  final String uid;
  final String? email;
  final bool emailVerified;
  final bool isAnonymous;
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthRepository {
  /// Emits the current user (or null) immediately, then on every change. Restores sessions on app start.
  Stream<AuthUser?> authStateChanges();
  AuthUser? get currentUser;
  Future<String?> idToken();
  Future<void> signInWithEmail(String email, String password);
  Future<void> registerWithEmail(String email, String password);
  Future<void> signInWithGoogle();
  Future<void> signInAnonymously();
  Future<void> sendPasswordReset(String email);
  Future<void> sendEmailVerification();
  Future<void> signOut();

  /// True when running without Firebase (LOCAL DEV only).
  bool get isLocalDev;
}

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({fb.FirebaseAuth? auth, this.googleServerClientId}) : _auth = auth ?? fb.FirebaseAuth.instance;
  final fb.FirebaseAuth _auth;
  final String? googleServerClientId;
  static bool _googleReady = false;

  AuthUser? _map(fb.User? u) =>
      u == null ? null : AuthUser(uid: u.uid, email: u.email, emailVerified: u.emailVerified, isAnonymous: u.isAnonymous);

  @override
  Stream<AuthUser?> authStateChanges() => _auth.authStateChanges().map(_map);
  @override
  AuthUser? get currentUser => _map(_auth.currentUser);
  @override
  bool get isLocalDev => false;

  @override
  Future<String?> idToken() async => _auth.currentUser?.getIdToken();

  Future<T> _guard<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on fb.FirebaseAuthException catch (e) {
      throw AuthException(_friendly(e.code));
    } on GoogleSignInException catch (e) {
      throw AuthException(e.code == GoogleSignInExceptionCode.canceled ? 'Sign-in was cancelled.' : 'Google sign-in failed. Please try again.');
    }
  }

  static String _friendly(String code) => switch (code) {
        'invalid-email' => 'That email address looks invalid.',
        'user-disabled' => 'This account has been disabled.',
        'user-not-found' || 'wrong-password' || 'invalid-credential' => 'Incorrect email or password.',
        'email-already-in-use' => 'An account already exists for that email.',
        'weak-password' => 'Choose a stronger password (at least 6 characters).',
        'network-request-failed' => 'No connection. Check your network and retry.',
        'too-many-requests' => 'Too many attempts. Please wait a moment and try again.',
        'operation-not-allowed' => 'This sign-in method is not enabled for the project.',
        _ => 'Authentication failed. Please try again.',
      };

  @override
  Future<void> signInWithEmail(String email, String password) =>
      _guard(() => _auth.signInWithEmailAndPassword(email: email.trim(), password: password));

  @override
  Future<void> registerWithEmail(String email, String password) => _guard(() async {
        final c = await _auth.createUserWithEmailAndPassword(email: email.trim(), password: password);
        await c.user?.sendEmailVerification();
      });

  @override
  Future<void> signInWithGoogle() => _guard(() async {
        final g = GoogleSignIn.instance;
        if (!_googleReady) {
          await g.initialize(serverClientId: googleServerClientId);
          _googleReady = true;
        }
        final acct = await g.authenticate();
        final cred = fb.GoogleAuthProvider.credential(idToken: acct.authentication.idToken);
        await _auth.signInWithCredential(cred);
      });

  @override
  Future<void> signInAnonymously() => _guard(() => _auth.signInAnonymously());
  @override
  Future<void> sendPasswordReset(String email) => _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));
  @override
  Future<void> sendEmailVerification() => _guard(() async => _auth.currentUser?.sendEmailVerification());
  @override
  Future<void> signOut() async {
    await _auth.signOut();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}

/// LOCAL DEV ONLY. Pairs with the API's AUTH_MODE=dev (`Bearer dev:<uid>`), which the API refuses in prod.
/// Any email + password of 6+ chars "works"; there is no real account security here.
class DevAuthRepository implements AuthRepository {
  DevAuthRepository({FlutterSecureStorage? storage}) : _store = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _store;
  final _ctrl = StreamController<AuthUser?>.broadcast();
  AuthUser? _user;
  bool _loaded = false;

  @override
  bool get isLocalDev => true;
  @override
  AuthUser? get currentUser => _user;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final uid = await _store.read(key: 'dev_uid');
      final email = await _store.read(key: 'dev_email');
      if (uid != null) _user = AuthUser(uid: uid, email: email, emailVerified: true, isAnonymous: email == null);
    } catch (_) {}
  }

  Future<void> _set(AuthUser u) async {
    _user = u;
    try {
      await _store.write(key: 'dev_uid', value: u.uid);
      if (u.email != null) await _store.write(key: 'dev_email', value: u.email);
    } catch (_) {}
    _ctrl.add(u);
  }

  @override
  Stream<AuthUser?> authStateChanges() async* {
    await _load();
    yield _user;
    yield* _ctrl.stream;
  }

  @override
  Future<String?> idToken() async {
    await _load();
    return _user == null ? null : 'dev:${_user!.uid}';
  }

  static String _uidFor(String email) => 'dev-${email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

  @override
  Future<void> signInWithEmail(String email, String password) async {
    if (password.length < 6) throw AuthException('Incorrect email or password.');
    await _set(AuthUser(uid: _uidFor(email), email: email.trim(), emailVerified: true));
  }

  @override
  Future<void> registerWithEmail(String email, String password) => signInWithEmail(email, password);
  @override
  Future<void> signInWithGoogle() async => throw AuthException('Google sign-in needs Firebase (run with FIREBASE_ENABLED=true).');
  @override
  Future<void> signInAnonymously() async => _set(AuthUser(uid: 'demo-${Random().nextInt(1 << 32).toRadixString(16)}', isAnonymous: true));
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<void> sendEmailVerification() async {}
  @override
  Future<void> signOut() async {
    _user = null;
    try {
      await _store.delete(key: 'dev_uid');
      await _store.delete(key: 'dev_email');
    } catch (_) {}
    _ctrl.add(null);
  }
}
