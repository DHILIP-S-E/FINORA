import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

typedef Json = Map<String, dynamic>;

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, [this.details = const {}]);
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  bool get isAiUnavailable => code == 'ai_unavailable';
  bool get isIncomplete => code == 'incomplete_inputs';
  bool get isNetwork => status == 0;

  @override
  String toString() => message;
}

/// Backend contract. The UI depends on this interface only, so tests can substitute a fake.
abstract class CascadeApi {
  Future<Json> getProfile();
  Future<Json> putProfile(Json body);
  Future<List<Json>> listRecords();
  Future<Json> createRecord(Json body);
  Future<Json> patchRecord(String id, Json body);
  Future<void> deleteRecord(String id);
  Future<Json> getCashflow({int horizonDays = 60});
  Future<Json> recalculate();
  Future<List<Json>> listEvents();
  Future<Json> createEvent(Json body);
  Future<Json> patchEvent(String id, Json body);
  Future<void> deleteEvent(String id);
  Future<Json> undoEvent(String id);
  Future<Json> discover({int horizonDays = 60});
  Future<Json> saveScenario(Json body);
  Future<List<Json>> listScenarios();
  Future<Json> getScenario(String id);
  Future<Json> simulate(String id, {List<Json>? disruptions});
  Future<Json> compare(String id, {List<Json>? alternative});
  Future<Json> interventions(String id);
  Future<void> deleteScenario(String id);
  Future<Json> assistant(String message);
  Future<List<Json>> listAlerts();
  Future<Json> patchAlert(String id, Json body);
  Future<Json> getPrefs();
  Future<Json> putPrefs(Json body);
  Future<List<Json>> listDocuments();
  Future<Json> uploadDocument(List<int> bytes, String filename, String mime);
  Future<Json> extractDocument(String id);
  Future<Json> getDocument(String id);
  Future<Json> confirmDocument(String id, List<Json> records);
  Future<void> deleteDocument(String id);
  Future<Json> exportAccount();
  Future<void> deleteAccount();
  Future<Json> seedDemo();
  Future<void> resetDemo();
}

class HttpCascadeApi implements CascadeApi {
  HttpCascadeApi({required this.baseUrl, required this.token, this.extraHeaders, http.Client? client}) : _http = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() token;
  final Future<Map<String, String>> Function()? extraHeaders;
  final http.Client _http;
  static const _timeout = Duration(seconds: 60);

  Future<dynamic> _send(String method, String path,
      {Json? body, Map<String, String>? query, http.MultipartFile? file}) async {
    final t = await token();
    final uri = Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: query);
    final headers = {'Accept': 'application/json', if (t != null) 'Authorization': 'Bearer $t', ...?await extraHeaders?.call()};
    try {
      late http.Response res;
      if (file != null) {
        final req = http.MultipartRequest(method, uri)..headers.addAll(headers)..files.add(file);
        res = await http.Response.fromStream(await _http.send(req).timeout(_timeout));
      } else {
        final h = {...headers, if (body != null) 'Content-Type': 'application/json'};
        final enc = body == null ? null : jsonEncode(body);
        final f = switch (method) {
          'GET' => _http.get(uri, headers: h),
          'POST' => _http.post(uri, headers: h, body: enc),
          'PUT' => _http.put(uri, headers: h, body: enc),
          'PATCH' => _http.patch(uri, headers: h, body: enc),
          'DELETE' => _http.delete(uri, headers: h),
          _ => throw ArgumentError(method),
        };
        res = await f.timeout(_timeout);
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.isEmpty) return null;
        return jsonDecode(utf8.decode(res.bodyBytes));
      }
      Json? err;
      try {
        err = (jsonDecode(utf8.decode(res.bodyBytes)) as Json)['error'] as Json?;
      } catch (_) {}
      throw ApiException(res.statusCode, err?['code'] as String? ?? 'http_${res.statusCode}',
          err?['message'] as String? ?? 'Request failed (${res.statusCode})', (err?['details'] as Map?)?.cast<String, dynamic>() ?? {});
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException(0, 'network_error', 'Can\'t reach the server. Check your connection and try again.');
    }
  }

  Future<Json> _obj(String m, String p, {Json? body, Map<String, String>? query}) async =>
      (await _send(m, p, body: body, query: query) as Json?) ?? {};

  Future<List<Json>> _items(String p) async =>
      ((await _send('GET', p, query: {'limit': '200'}) as Json)['items'] as List).cast<Json>();

  @override
  Future<Json> getProfile() => _obj('GET', '/profile');
  @override
  Future<Json> putProfile(Json body) => _obj('PUT', '/profile', body: body);
  @override
  Future<List<Json>> listRecords() => _items('/records');
  @override
  Future<Json> createRecord(Json body) => _obj('POST', '/records', body: body);
  @override
  Future<Json> patchRecord(String id, Json body) => _obj('PATCH', '/records/$id', body: body);
  @override
  Future<void> deleteRecord(String id) => _send('DELETE', '/records/$id');
  @override
  Future<Json> getCashflow({int horizonDays = 60}) => _obj('GET', '/cashflow', query: {'horizon_days': '$horizonDays'});
  @override
  Future<Json> recalculate() => _obj('POST', '/cashflow/recalculate');
  @override
  Future<List<Json>> listEvents() => _items('/cashflow/events');
  @override
  Future<Json> createEvent(Json body) => _obj('POST', '/cashflow/events', body: body);
  @override
  Future<Json> patchEvent(String id, Json body) => _obj('PATCH', '/cashflow/events/$id', body: body);
  @override
  Future<void> deleteEvent(String id) => _send('DELETE', '/cashflow/events/$id');
  @override
  Future<Json> undoEvent(String id) => _obj('POST', '/cashflow/events/$id/undo');
  @override
  Future<Json> discover({int horizonDays = 60}) => _obj('POST', '/scenarios/discover', body: {'horizon_days': horizonDays});
  @override
  Future<Json> saveScenario(Json body) => _obj('POST', '/scenarios', body: body);
  @override
  Future<List<Json>> listScenarios() => _items('/scenarios');
  @override
  Future<Json> getScenario(String id) => _obj('GET', '/scenarios/$id');
  @override
  Future<Json> simulate(String id, {List<Json>? disruptions}) =>
      _obj('POST', '/scenarios/$id/simulate', body: {if (disruptions != null) 'disruptions': disruptions});
  @override
  Future<Json> compare(String id, {List<Json>? alternative}) =>
      _obj('POST', '/scenarios/$id/compare', body: {if (alternative != null) 'alternative_disruptions': alternative});
  @override
  Future<Json> interventions(String id) => _obj('POST', '/scenarios/$id/interventions');
  @override
  Future<void> deleteScenario(String id) => _send('DELETE', '/scenarios/$id');
  @override
  Future<Json> assistant(String message) => _obj('POST', '/assistant/query', body: {'message': message});
  @override
  Future<List<Json>> listAlerts() => _items('/alerts');
  @override
  Future<Json> patchAlert(String id, Json body) => _obj('PATCH', '/alerts/$id', body: body);
  @override
  Future<Json> getPrefs() => _obj('GET', '/notification-preferences');
  @override
  Future<Json> putPrefs(Json body) => _obj('PUT', '/notification-preferences', body: body);
  @override
  Future<List<Json>> listDocuments() => _items('/documents');
  @override
  Future<Json> uploadDocument(List<int> bytes, String filename, String mime) async {
    final parts = mime.split('/');
    final file = http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType(parts[0], parts[1]));
    return (await _send('POST', '/documents', file: file) as Json);
  }

  @override
  Future<Json> extractDocument(String id) => _obj('POST', '/documents/$id/extract');
  @override
  Future<Json> getDocument(String id) => _obj('GET', '/documents/$id');
  @override
  Future<Json> confirmDocument(String id, List<Json> records) => _obj('POST', '/documents/$id/confirm', body: {'records': records});
  @override
  Future<void> deleteDocument(String id) => _send('DELETE', '/documents/$id');
  @override
  Future<Json> exportAccount() => _obj('POST', '/account/export');
  @override
  Future<void> deleteAccount() => _send('DELETE', '/account');
  @override
  Future<Json> seedDemo() => _obj('POST', '/demo/seed');
  @override
  Future<void> resetDemo() => _send('POST', '/demo/reset');
}
