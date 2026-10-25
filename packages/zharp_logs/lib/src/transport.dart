import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'version.dart';

/// Where logs go unless `endpoint` says otherwise.
const String defaultEndpoint = 'https://api.zharp.io/api/v1';

/// Largest body one request carries. The backend accepts 10 MB; staying far below it keeps one
/// slow upload from holding everything behind it. An entry larger than this on its own is still
/// sent alone rather than dropped.
const int maxRequestBytes = 1000000;

/// Trim a configured endpoint so paths can be appended to it.
String normalizeEndpoint(String? endpoint) =>
    (endpoint == null || endpoint.trim().isEmpty ? defaultEndpoint : endpoint.trim()).replaceAll(RegExp(r'/+$'), '');

/// Sends batches of log entries to `{endpoint}/agent/logs` as `{"logs": [...]}`.
class Transport {
  Transport({
    required this.apiKey,
    required this.endpoint,
    required this.client,
    this.retryDelay = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 15),
  });

  final String apiKey;
  final String endpoint;
  final http.Client client;

  /// The first retry waits twice this, the second four times.
  final Duration retryDelay;
  final Duration timeout;

  Future<void> send(List<Map<String, Object?>> entries) async {
    // Cut by bytes rather than count: fifty entries carrying stack traces can be megabytes, and
    // one oversized request would be rejected whole.
    for (final body in splitBySize(entries, maxRequestBytes)) {
      await _sendBody(body);
    }
  }

  /// Three attempts in all. Only network errors and 5xx responses are retried — a 4xx won't be
  /// fixed by sending the same thing again.
  Future<void> _sendBody(String body) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await client
            .post(
              Uri.parse('$endpoint/agent/logs'),
              // The key goes in a header, never the URL: URLs end up in proxy logs.
              headers: {'Content-Type': 'application/json', 'X-API-KEY': apiKey, 'X-Zharp-SDK': sdkName},
              body: body,
            )
            .timeout(timeout);
        if (response.statusCode < 500) return;
      } catch (_) {
        // Network failure or timeout — fall through to retry.
      }
      if (attempt < 2) await Future<void>.delayed(retryDelay * (2 << attempt));
    }
  }
}

/// `{"logs": [...]}` bodies of at most [limit] bytes each. An entry too large to fit even alone
/// still gets a body of its own: whether it can be delivered is for the network to decide.
List<String> splitBySize(List<Map<String, Object?>> entries, int limit) {
  final overhead = utf8.encode('{"logs":[]}').length;
  final bodies = <String>[];
  var group = <String>[];
  var size = overhead;
  for (final entry in entries) {
    final json = jsonEncode(entry);
    final entrySize = utf8.encode(json).length + 1; // +1 for the separating comma
    if (group.isNotEmpty && size + entrySize > limit) {
      bodies.add('{"logs":[${group.join(',')}]}');
      group = [];
      size = overhead;
    }
    group.add(json);
    size += entrySize;
  }
  if (group.isNotEmpty) bodies.add('{"logs":[${group.join(',')}]}');
  return bodies;
}
