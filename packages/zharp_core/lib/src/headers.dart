/// Request and response headers on HTTP CLIENT spans, as OpenTelemetry names them
/// (`http.request.header.user-agent`, `http.response.header.x-request-id`), so a failed request
/// shows what was sent and what came back — and what wasn't sent (no `authorization`). Secret
/// headers are recorded as `[Filtered]`: sent, but the value never leaves the device. The same
/// rules as every other Zharp SDK (the reference is @zharp/internal/headers in the JS SDK).
library;

import 'bodies.dart';

/// Secret whatever the key rules say.
const Set<String> _secret = {
  'authorization', 'proxy-authorization', 'cookie', 'set-cookie', 'x-api-key', 'x-auth-token', 'x-csrf-token', 'x-xsrf-token',
};

/// Per side, so a request stuffed with headers can't fill the span.
const int _maxHeaders = 40;
const int _maxValue = 512;

/// `http.<side>.header.<name>` attributes: secrets filtered, long values cut, repeats joined.
Map<String, Object?> headerAttributes(String side, Iterable<MapEntry<String, String>> headers, List<Pattern> redact) {
  final joined = <String, List<String>>{};
  for (final entry in headers) {
    final name = entry.key.toLowerCase();
    if (!joined.containsKey(name) && joined.length >= _maxHeaders) continue;
    (joined[name] ??= []).add(entry.value);
  }
  return {
    for (final entry in joined.entries)
      'http.$side.header.${entry.key}': _secret.contains(entry.key) || isSecretKey(entry.key, redact)
          ? filtered
          : _cut(entry.value.join(', ')),
  };
}

String _cut(String text) => text.length > _maxValue ? '${text.substring(0, _maxValue)}…' : text;
