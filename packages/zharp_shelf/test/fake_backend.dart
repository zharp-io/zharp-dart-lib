import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake Zharp ingest that records what it was sent and answers with [status].
class FakeBackend {
  FakeBackend({this.status = 200});

  int status;
  Map<String, String> responseHeaders = const {};
  bool offline = false;
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) async {
    if (offline) throw const SocketException('offline');
    requests.add(request);
    return http.Response('{}', status, headers: responseHeaders);
  });

  /// The JSON a request carried, gunzipped when it was.
  static Map<String, dynamic> body(http.Request request) {
    final bytes = request.headers['Content-Encoding'] == 'gzip' ? gzip.decode(request.bodyBytes) : request.bodyBytes;
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Iterable<http.Request> to(String path) => requests.where((r) => r.url.path.endsWith('/v1/$path'));

  List<Map<String, dynamic>> get spans => [
        for (final r in to('traces'))
          for (final rs in body(r)['resourceSpans'] as List)
            for (final ss in rs['scopeSpans'] as List) ...(ss['spans'] as List).cast<Map<String, dynamic>>(),
      ];

  List<Map<String, dynamic>> get logs => [
        for (final r in to('logs'))
          for (final rl in body(r)['resourceLogs'] as List)
            for (final sl in rl['scopeLogs'] as List) ...(sl['logRecords'] as List).cast<Map<String, dynamic>>(),
      ];

  Map<String, Object?> resourceOf(http.Request request) {
    final b = body(request);
    final list = (b['resourceSpans'] ?? b['resourceLogs']) as List;
    return attrs(list.first['resource']['attributes'] as List);
  }
}

/// An OTLP KeyValue list as a plain map.
Map<String, Object?> attrs(List<dynamic>? list) => {
      for (final kv in list ?? const []) kv['key'] as String: _value(kv['value'] as Map<String, dynamic>),
    };

Object? _value(Map<String, dynamic> v) {
  if (v.containsKey('stringValue')) return v['stringValue'];
  if (v.containsKey('intValue')) return int.parse(v['intValue'] as String);
  if (v.containsKey('boolValue')) return v['boolValue'];
  if (v.containsKey('doubleValue')) return v['doubleValue'];
  if (v.containsKey('arrayValue')) {
    return [for (final x in v['arrayValue']['values'] as List) _value(x as Map<String, dynamic>)];
  }
  if (v.containsKey('kvlistValue')) return attrs(v['kvlistValue']['values'] as List);
  return null;
}
