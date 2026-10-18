import 'dart:convert';

import 'package:cascade/core/api.dart';
import 'package:cascade/core/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cascade/widgets/forms.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('Currency formatting & parsing (integer minor units)', () {
    test('INR uses lakh grouping', () {
      expect(Currency.inr.format(12345678), '₹1,23,456.78');
      expect(Currency.inr.format(-500), '-₹5.00');
      expect(Currency.inr.format(5), '₹0.05');
      expect(Currency.inr.format(100000000), '₹10,00,000.00');
    });
    test('USD uses western grouping', () {
      expect(Currency.usd.format(123456789), r'$1,234,567.89');
    });
    test('compact format', () {
      expect(Currency.inr.format(4200000, compact: true), '₹42.0k');
      expect(Currency.inr.format(-1250000000, compact: true), '-₹125L');
    });
    test('parse accepts commas and rejects too many decimals / junk', () {
      expect(Currency.inr.parse('12,500.50'), 1250050);
      expect(Currency.inr.parse('₹100'), 10000);
      expect(Currency.inr.parse('0.1'), 10);
      expect(Currency.inr.parse('1.234'), isNull);
      expect(Currency.inr.parse('abc'), isNull);
      expect(Currency.inr.parse(''), isNull);
      expect(Currency.inr.parse('1e5'), isNull);
    });
    test('no floating point drift: 0.1 + 0.2 style values', () {
      expect(Currency.inr.parse('0.10')! + Currency.inr.parse('0.20')!, 30);
    });
    test('plain round-trips', () {
      for (final s in ['0.00', '12.05', '99999.99']) {
        expect(Currency.inr.plain(Currency.inr.parse(s)!), s);
      }
    });
  });

  group('validators', () {
    test('email', () {
      expect(validateEmail('a@b.co'), isNull);
      expect(validateEmail('nope'), isNotNull);
      expect(validateEmail(null), isNotNull);
    });
    test('password', () {
      expect(validatePassword('1234567'), isNotNull);
      expect(validatePassword('12345678'), isNull);
      expect(validatePassword('123456', min: 6), isNull);
    });
    test('isoDate', () => expect(isoDate(DateTime(2026, 3, 5)), '2026-03-05'));
  });

  group('HttpCascadeApi (mocked transport)', () {
    HttpCascadeApi api(MockClientHandler h, {String? token = 't'}) =>
        HttpCascadeApi(baseUrl: 'http://x', token: () async => token, client: MockClient(h));

    test('sends bearer token and decodes json', () async {
      late http.Request seen;
      final a = api((r) async {
        seen = r;
        return http.Response(jsonEncode({'currency': 'INR'}), 200);
      });
      final p = await a.getProfile();
      expect(p['currency'], 'INR');
      expect(seen.headers['Authorization'], 'Bearer t');
      expect(seen.url.path, '/api/v1/profile');
    });

    test('maps API error envelope to ApiException', () async {
      final a = api((_) async => http.Response(jsonEncode({'error': {'code': 'ai_unavailable', 'message': 'AI is down', 'details': {}}}), 503));
      await expectLater(a.discover(), throwsA(isA<ApiException>().having((e) => e.isAiUnavailable, 'isAiUnavailable', true).having((e) => e.message, 'message', 'AI is down')));
    });

    test('network failure becomes a friendly offline error', () async {
      final a = api((_) async => throw Exception('socket'));
      await expectLater(a.getProfile(), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)));
    });

    test('list endpoints unwrap items', () async {
      final a = api((_) async => http.Response(jsonEncode({'items': [{'id': '1'}, {'id': '2'}], 'next_cursor': null}), 200));
      expect((await a.listRecords()).length, 2);
    });

    test('204 delete succeeds', () async {
      final a = api((r) async => http.Response('', 204));
      await a.deleteRecord('abc');
    });

    test('omits Authorization when signed out', () async {
      late http.Request seen;
      final a = api((r) async {
        seen = r;
        return http.Response('{}', 200);
      }, token: null);
      await a.getProfile();
      expect(seen.headers.containsKey('Authorization'), false);
    });
  });

  testWidgets('MoneyField validation', (t) async {
    final c = TextEditingController();
    final key = GlobalKey<FormState>();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Form(key: key, child: MoneyField(controller: c, currency: Currency.inr)))));
    expect(key.currentState!.validate(), false);
    c.text = '0';
    expect(key.currentState!.validate(), false);
    c.text = '12.345';
    expect(key.currentState!.validate(), false);
    c.text = '1,200.50';
    expect(key.currentState!.validate(), true);
  });
}
