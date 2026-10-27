import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'env.dart';
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
    this.keyRetryDelay = const Duration(hours: 1),
  });

  final String apiKey;
  final String endpoint;
  final http.Client client;

  /// The first retry waits twice this, the second four times.
  final Duration retryDelay;
  final Duration timeout;

  /// How long a rejected key waits before one batch is tried again.
  final Duration keyRetryDelay;

  /// While Zharp rejects the key (401/403): when the next batch may go out. Null while accepted.
  ///
  /// A deleted or revoked key stays rejected, so sending every batch would only be refused
  /// forever. The first rejection prints one warning; after that batches are dropped, not kept,
  /// so memory stays bounded, until [keyRetryDelay] has passed and one batch is tried again. If
  /// it is accepted, sending resumes and says so once; if not, the next try is a wait later.
  DateTime? _retryAt;

  /// The one batch tried after the wait is in flight.
  bool _probing = false;

  Future<void> send(List<Map<String, Object?>> entries) async {
    // Cut by bytes rather than count: fifty entries carrying stack traces can be megabytes, and
    // one oversized request would be rejected whole.
    for (final body in splitBySize(entries, maxRequestBytes)) {
      await _sendBody(body);
    }
  }

  /// Three attempts in all. Only network errors and 5xx responses are retried — a 4xx won't be
  /// fixed by sending the same thing again. A rejected key (401/403) stops sending altogether for
  /// a while: see [_retryAt].
  Future<void> _sendBody(String body) async {
    if (!_allow()) return;
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
        if (_rejected(response.statusCode)) return;
        if (response.statusCode < 500) return;
      } catch (_) {
        // Network failure or timeout — fall through to retry.
        _failed();
      }
      if (attempt < 2) await Future<void>.delayed(retryDelay * (2 << attempt));
    }
  }

  /// Whether a batch may go out now: always while the key is accepted, then one per wait.
  bool _allow() {
    final retryAt = _retryAt;
    if (retryAt == null) return true;
    if (_probing || DateTime.now().isBefore(retryAt)) return false;
    _probing = true;
    return true;
  }

  /// Notes a response; true when the key was rejected, so the batch is dropped, not retried.
  bool _rejected(int status) {
    final wasBackedOff = _retryAt != null;
    _probing = false;
    if (status == 401 || status == 403) {
      if (!wasBackedOff) {
        announce('Zharp rejected this API key (HTTP $status) — logs are not being sent. Check ZHARP_API_KEY.');
      }
      _retryAt = DateTime.now().add(keyRetryDelay);
      return true;
    }
    if (wasBackedOff) {
      if (status >= 200 && status < 300) {
        _retryAt = null;
        announce('Zharp accepted the API key again — logs are being sent.');
      } else {
        // Neither accepted nor rejected (a server error): try again after the next wait.
        _retryAt = DateTime.now().add(keyRetryDelay);
      }
    }
    return false;
  }

  /// The tried batch never got a response: wait again rather than stay stuck mid-try.
  void _failed() {
    if (!_probing) return;
    _probing = false;
    _retryAt = DateTime.now().add(keyRetryDelay);
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
