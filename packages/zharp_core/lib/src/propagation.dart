/// W3C Trace Context and Baggage: the headers that carry a trace from the app to its back end.
library;

import 'ids.dart';

/// `traceparent: 00-<trace-id>-<parent-id>-<flags>`.
String formatTraceparent(String traceId, String spanId, {required bool sampled}) =>
    '00-$traceId-$spanId-${sampled ? '01' : '00'}';

/// A parsed `traceparent`, or null when the header is malformed.
({String traceId, String spanId, bool sampled})? parseTraceparent(String? header) {
  if (header == null) return null;
  final parts = header.trim().toLowerCase().split('-');
  if (parts.length < 4) return null;
  final version = parts[0];
  if (version.length != 2 || version == 'ff') return null;
  if (version == '00' && parts.length != 4) return null;
  final traceId = parts[1];
  final spanId = parts[2];
  final flags = int.tryParse(parts[3], radix: 16);
  if (!isValidTraceId(traceId) || !isValidSpanId(spanId) || parts[3].length != 2 || flags == null) return null;
  return (traceId: traceId, spanId: spanId, sampled: flags & 1 == 1);
}

/// `baggage: enduser.id=42,session.id=…` — values percent-encoded, empty ones left out.
String formatBaggage(Map<String, String?> entries) => [
      for (final entry in entries.entries)
        if (entry.value != null && entry.value!.isNotEmpty)
          '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value!)}',
    ].join(',');

/// A `baggage` header as a map. Properties (`;…`) are ignored.
Map<String, String> parseBaggage(String? header) {
  final out = <String, String>{};
  if (header == null) return out;
  for (final member in header.split(',')) {
    final pair = member.split(';').first;
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    try {
      out[Uri.decodeComponent(pair.substring(0, eq).trim())] = Uri.decodeComponent(pair.substring(eq + 1).trim());
    } catch (_) {
      // A malformed escape: skip that member.
    }
  }
  return out;
}

/// Combine baggage the request already had with Zharp's entries; Zharp's keys replace theirs.
String mergeBaggage(String? existing, Map<String, String?> ours) {
  final merged = <String, String?>{...parseBaggage(existing), ...ours};
  return formatBaggage(merged);
}

/// Whether requests to [url] may carry trace headers, given the `tracingOrigins` option.
///
/// Each entry is a [Pattern]:
/// - a host, `api.example.com` — that host on any scheme and port;
/// - a wildcard host, `*.example.com` — any subdomain of example.com (not example.com itself);
/// - an origin, `https://api.example.com:8443` — exactly that scheme, host and port;
/// - a [RegExp] — matched against the whole URL.
///
/// Nothing matches by default: trace headers are never sent to third parties unless listed.
bool shouldPropagate(Uri url, List<Pattern> tracingOrigins) {
  if (!url.hasScheme || !(url.isScheme('http') || url.isScheme('https'))) return false;
  final host = url.host.toLowerCase();
  for (final pattern in tracingOrigins) {
    if (pattern is RegExp) {
      if (pattern.hasMatch(url.toString())) return true;
      continue;
    }
    final entry = pattern.toString().trim().toLowerCase();
    if (entry.isEmpty) continue;
    if (entry.contains('://')) {
      final origin = Uri.tryParse(entry);
      if (origin != null && origin.scheme == url.scheme && origin.host == host && origin.port == url.port) return true;
      continue;
    }
    if (entry.startsWith('*.')) {
      if (host.endsWith(entry.substring(1))) return true;
      continue;
    }
    // A bare host, optionally with a port.
    final colon = entry.lastIndexOf(':');
    if (colon > 0 && int.tryParse(entry.substring(colon + 1)) != null) {
      if (entry.substring(0, colon) == host && int.parse(entry.substring(colon + 1)) == url.port) return true;
    } else if (entry == host) {
      return true;
    }
  }
  return false;
}
