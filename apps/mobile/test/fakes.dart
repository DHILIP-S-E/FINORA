import 'dart:async';

import 'package:cascade/auth/auth_repository.dart';
import 'package:cascade/core/api.dart';

/// In-memory auth for tests (mocked Firebase boundary).
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({AuthUser? initial, this.failWith}) : _user = initial;
  AuthUser? _user;
  final String? failWith;
  final _ctrl = StreamController<AuthUser?>.broadcast();
  final calls = <String>[];

  @override
  bool get isLocalDev => false;
  @override
  AuthUser? get currentUser => _user;
  @override
  Stream<AuthUser?> authStateChanges() async* {
    yield _user;
    yield* _ctrl.stream;
  }

  @override
  Future<String?> idToken() async => _user == null ? null : 'token-${_user!.uid}';

  void _set(AuthUser? u) {
    _user = u;
    _ctrl.add(u);
  }

  void _maybeFail() {
    if (failWith != null) throw AuthException(failWith!);
  }

  @override
  Future<void> signInWithEmail(String email, String password) async {
    calls.add('signIn:$email');
    _maybeFail();
    _set(AuthUser(uid: 'u1', email: email, emailVerified: true));
  }

  @override
  Future<void> registerWithEmail(String email, String password) async {
    calls.add('register:$email');
    _maybeFail();
    _set(AuthUser(uid: 'u1', email: email));
  }

  @override
  Future<void> signInWithGoogle() async {
    calls.add('google');
    _set(const AuthUser(uid: 'g1', email: 'g@example.com', emailVerified: true));
  }

  @override
  Future<void> signInAnonymously() async {
    calls.add('anon');
    _set(const AuthUser(uid: 'anon', isAnonymous: true));
  }

  @override
  Future<void> sendPasswordReset(String email) async => calls.add('reset:$email');
  @override
  Future<void> sendEmailVerification() async => calls.add('verify');
  @override
  Future<void> signOut() async {
    calls.add('signOut');
    _set(null);
  }
}

/// Fake backend implementing the full contract with canned, synthetic data.
class FakeApi implements CascadeApi {
  FakeApi({this.withBalance = true});
  final bool withBalance;
  final saved = <Json>[];
  final calls = <String>[];
  final records = <Json>[];

  Json get _summary => {
        'complete': true, 'incomplete_reasons': [], 'currency': 'INR', 'opening_balance_minor': 4200000,
        'lowest_balance_minor': 1780000, 'lowest_balance_date': '2026-10-30', 'closing_balance_minor': 1780000,
        'shortfall': null, 'order_sensitive_dates': [], 'assumptions_applied': [], 'excluded_or_unknown': [], 'requires_external_confirmation': [],
      };

  List<Json> _daily({int shift = 0}) => [
        for (var i = 0; i < 30; i++) {'date': '2026-10-${(20 + i % 10).toString().padLeft(2, '0')}', 'closing_minor': 4200000 - i * 50000 - (i > 12 ? shift : 0), 'pessimistic_intraday_min_minor': 0},
      ];

  @override
  Future<Json> getProfile() async => {
        'currency': 'INR', 'opening_balance_minor': withBalance ? 4200000 : null, 'balance_as_of': withBalance ? '2026-10-20' : null,
        'onboarding_complete': withBalance, 'is_demo': true,
      };
  @override
  Future<Json> putProfile(Json body) async => body;
  @override
  Future<List<Json>> listRecords() async => records;
  @override
  Future<Json> createRecord(Json body) async {
    calls.add('createRecord');
    final r = {...body, 'id': 'r${records.length}'};
    records.add(r);
    return r;
  }

  @override
  Future<Json> patchRecord(String id, Json body) async => body;
  @override
  Future<void> deleteRecord(String id) async => records.removeWhere((r) => r['id'] == id);
  @override
  Future<Json> getCashflow({int horizonDays = 60}) async => {
        'actual_balance': {'amount_minor': withBalance ? 4200000 : null, 'as_of': '2026-10-20', 'kind': 'actual_user_reported', 'stale_days': 0},
        'projection': withBalance
            ? {'kind': 'projected', 'summary': _summary, 'daily': _daily(), 'weekly': [], 'monthly': []}
            : {'kind': 'projected', 'summary': {..._summary, 'complete': false, 'incomplete_reasons': ['Opening cash balance is missing.']}, 'daily': [], 'weekly': [], 'monthly': []},
        'events': [
          {'date': '2026-10-26', 'event_id': 'rent@2026-10-26', 'source_record_id': 'rent', 'label': 'Rent', 'kind': 'essential_expense', 'status': 'scheduled', 'delta_minor': -1800000, 'balance_after_minor': 2400000},
          {'date': '2026-10-26', 'event_id': 'client@2026-10-26', 'source_record_id': 'client', 'label': 'Client A', 'kind': 'income', 'status': 'estimated', 'delta_minor': 6000000, 'balance_after_minor': 8400000},
        ],
        'missing_information': ['Grace period for \'Personal loan EMI\' is unknown.'],
        'is_demo': true, 'reserve_minor': 0,
      };
  @override
  Future<Json> recalculate() async => {'new_alerts': [], 'count': 0};
  @override
  Future<List<Json>> listEvents() async => [];
  @override
  Future<Json> createEvent(Json body) async => {...body, 'id': 'e1'};
  @override
  Future<Json> patchEvent(String id, Json body) async => body;
  @override
  Future<void> deleteEvent(String id) async {}
  @override
  Future<Json> undoEvent(String id) async => {};
  @override
  Future<Json> discover({int horizonDays = 60}) async => {
        'labels': {'live_ai': false, 'provider': 'fallback', 'hypotheses': 'rule_based_demo_fallback'},
        'candidates': [
          {
            'scenario_title': 'Late payment from Client A', 'scenario_summary': 'Income arrives 10 days later.', 'trigger_events': ['Client A delayed 10 days'],
            'assumptions': ['Delay of 10 days'], 'required_inputs': [], 'source_record_ids': [], 'time_horizon_days': 60, 'potential_impact': 'worsens_liquidity',
            'rationale': 'Fixed obligations stay due.', 'uncertainties': ['Delay length unknown'], 'interpretation_confidence': 'medium',
            'validation_status': 'validated', 'validation_reasons': [], 'disruptions': [{'type': 'income_delay', 'record_id': 'client', 'days': 10}],
            'evaluation': {..._summary, 'shortfall': {'first_date': '2026-10-29', 'max_deficit_minor': 4220000, 'days_negative': 7, 'obligations_at_risk': ['Rent']}},
            'compound_effect': null,
          },
        ],
        'baseline': _summary,
      };
  @override
  Future<Json> saveScenario(Json body) async {
    calls.add('saveScenario');
    saved.add(body);
    return {'scenario': {...body, 'id': 's${saved.length}'}, 'run': null};
  }

  @override
  Future<List<Json>> listScenarios() async => [for (var i = 0; i < saved.length; i++) {...saved[i], 'id': 's${i + 1}'}];
  @override
  Future<Json> getScenario(String id) async => {
        'scenario': {...saved.last, 'id': id, 'disruptions': saved.last['disruptions']}, 'latest_run': null, 'replay': {'matches_stored_result': true},
      };
  @override
  Future<Json> simulate(String id, {List<Json>? disruptions}) async => {};
  @override
  Future<Json> compare(String id, {List<Json>? alternative}) async {
    final risky = {
      ..._summary, 'lowest_balance_minor': -2440000,
      'shortfall': {'first_date': '2026-10-29', 'max_deficit_minor': 2440000, 'days_negative': 5, 'obligations_at_risk': ['rent@2026-10-26']},
      'daily': _daily(shift: 3000000), 'ledger': [{'event_id': 'rent@2026-10-26', 'label': 'Rent'}],
    };
    final base = {..._summary, 'daily': _daily(), 'ledger': []};
    return {
      'baseline_vs_risk': {'baseline': base, 'alternative': risky},
      if (alternative != null) 'risk_vs_alternative': {'baseline': risky, 'alternative': {...base, 'daily': _daily(shift: 500000)}},
      'sensitivity': [{'assumption': 'Income arrives 10 days late', 'impact_minor': 2440000, 'lowest_balance_without_minor': 0}],
      'explanation': 'Under this scenario cash could drop below zero.', 'explanation_source': 'template',
    };
  }

  @override
  Future<Json> interventions(String id) async => {'candidates': [], 'note': 'none'};
  @override
  Future<void> deleteScenario(String id) async {}
  @override
  Future<Json> assistant(String message) async {
    calls.add('assistant:$message');
    return {
      'answer': 'Under the assumptions of your what-if, cash could drop below zero.', 'answer_source': 'template', 'live_ai': false,
      'facts': ['Baseline lowest projected balance: INR 17800.00'], 'assumptions': ['Income arrives 10 days late'], 'hypotheses': [], 'citations': [],
      'simulation': _summary,
      'proposed_scenario': {'title': message, 'origin': 'natural_language', 'disruptions': [{'type': 'income_delay', 'record_id': 'client', 'days': 10}], 'horizon_days': 60, 'needs_confirmation': true, 'source_record_ids': []},
      'needs_clarification': false,
    };
  }

  @override
  Future<List<Json>> listAlerts() async => [];
  @override
  Future<Json> patchAlert(String id, Json body) async => body;
  @override
  Future<Json> getPrefs() async => {'push_enabled': true, 'min_shortfall_minor': 0, 'quiet_hours': null, 'fcm_token': null, 'alert_types': []};
  @override
  Future<Json> putPrefs(Json body) async => body;
  @override
  Future<List<Json>> listDocuments() async => [];
  @override
  Future<Json> uploadDocument(List<int> bytes, String filename, String mime) async => {'id': 'd1'};
  @override
  Future<Json> extractDocument(String id) async => {};
  @override
  Future<Json> getDocument(String id) async => {};
  @override
  Future<Json> confirmDocument(String id, List<Json> records) async => {};
  @override
  Future<void> deleteDocument(String id) async {}
  @override
  Future<Json> exportAccount() async => {};
  @override
  Future<void> deleteAccount() async {}
  @override
  Future<Json> seedDemo() async {
    calls.add('seedDemo');
    return {};
  }

  @override
  Future<void> resetDemo() async {}
}
