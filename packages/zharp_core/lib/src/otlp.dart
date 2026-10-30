/// OTLP/HTTP JSON encoding: the shapes `POST {endpoint}/v1/traces` and `/v1/logs` accept.
///
/// See https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding — IDs are hex strings,
/// 64-bit integers (timestamps) are decimal strings, enums are numbers.
library;

import 'dart:convert';

/// Attribute values Zharp keeps: anything else becomes text. Values longer than this are cut; the
/// server caps them at 16 KB anyway.
const int maxAttributeLength = 16 * 1024;

/// An attribute map with values made safe for OTLP: null values dropped, unsupported values as text.
///
/// Copied, so a later change to the caller's map doesn't change a record already queued.
Map<String, Object> sanitizeAttributes(Map<String, Object?>? attributes) {
  if (attributes == null || attributes.isEmpty) return {};
  final out = <String, Object>{};
  attributes.forEach((key, value) {
    if (key.isEmpty) return;
    final clean = _sanitize(value, 0);
    if (clean != null) out[key] = clean;
  });
  return out;
}

Object? _sanitize(Object? value, int depth) {
  if (value == null) return null;
  if (value is String) return _cap(value);
  if (value is bool || value is int) return value;
  if (value is double) return value.isFinite ? value : value.toString();
  if (value is num) return value.toDouble();
  if (depth < 4) {
    if (value is Iterable) return [for (final item in value) _sanitize(item, depth + 1) ?? ''];
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (entry.value != null) '${entry.key}': _sanitize(entry.value, depth + 1)!,
      };
    }
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is Enum) return value.name;
  try {
    return _cap(value.toString());
  } catch (_) {
    return '<${value.runtimeType}>';
  }
}

String _cap(String text) => text.length > maxAttributeLength ? text.substring(0, maxAttributeLength) : text;

/// A Dart value as an OTLP `AnyValue`.
Map<String, Object> anyValue(Object? value) {
  if (value == null) return const {'stringValue': ''};
  if (value is String) return {'stringValue': value};
  if (value is bool) return {'boolValue': value};
  // int64 is a decimal string in OTLP/JSON.
  if (value is int) return {'intValue': '$value'};
  if (value is double) return {'doubleValue': value};
  if (value is Iterable) {
    return {
      'arrayValue': {
        'values': [for (final item in value) anyValue(item)]
      },
    };
  }
  if (value is Map) {
    return {
      'kvlistValue': {
        'values': [
          for (final entry in value.entries) {'key': '${entry.key}', 'value': anyValue(entry.value)},
        ],
      },
    };
  }
  return {'stringValue': value.toString()};
}

/// An attribute map as an OTLP `KeyValue` list.
List<Map<String, Object>> keyValues(Map<String, Object> attributes) => [
      for (final entry in attributes.entries) {'key': entry.key, 'value': anyValue(entry.value)},
    ];

/// Nanoseconds since the epoch as the decimal string OTLP/JSON uses. Built from microseconds as
/// text, so it is exact on the web too, where numbers are doubles.
String nanosString(int microsecondsSinceEpoch) => microsecondsSinceEpoch <= 0 ? '0' : '${microsecondsSinceEpoch}000';

/// OTLP `SpanKind`.
enum SpanKind {
  internal(1),
  server(2),
  client(3),
  producer(4),
  consumer(5);

  const SpanKind(this.code);
  final int code;
}

/// OTLP `StatusCode`.
enum SpanStatusCode {
  unset(0),
  ok(1),
  error(2);

  const SpanStatusCode(this.code);
  final int code;
}

/// OTLP log severity numbers for the levels Zharp offers.
enum Severity {
  trace(1, 'TRACE'),
  debug(5, 'DEBUG'),
  info(9, 'INFO'),
  warn(13, 'WARN'),
  error(17, 'ERROR'),
  fatal(21, 'FATAL');

  const Severity(this.number, this.text);
  final int number;
  final String text;
}

/// A finished span, ready to export.
class SpanData {
  SpanData({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.name,
    required this.kind,
    required this.startMicros,
    required this.endMicros,
    required this.attributes,
    required this.events,
    required this.statusCode,
    this.statusMessage,
  });

  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final String name;
  final SpanKind kind;
  final int startMicros;
  final int endMicros;
  final Map<String, Object> attributes;
  final List<SpanEventData> events;
  final SpanStatusCode statusCode;
  final String? statusMessage;

  Map<String, Object> toOtlp() => {
        'traceId': traceId,
        'spanId': spanId,
        if (parentSpanId != null) 'parentSpanId': parentSpanId!,
        'name': name,
        'kind': kind.code,
        'startTimeUnixNano': nanosString(startMicros),
        'endTimeUnixNano': nanosString(endMicros),
        'attributes': keyValues(attributes),
        if (events.isNotEmpty) 'events': [for (final event in events) event.toOtlp()],
        'status': {
          'code': statusCode.code,
          if (statusMessage != null && statusMessage!.isNotEmpty) 'message': statusMessage!,
        },
      };
}

class SpanEventData {
  SpanEventData(this.name, this.timeMicros, this.attributes);

  final String name;
  final int timeMicros;
  final Map<String, Object> attributes;

  Map<String, Object> toOtlp() => {
        'name': name,
        'timeUnixNano': nanosString(timeMicros),
        if (attributes.isNotEmpty) 'attributes': keyValues(attributes),
      };
}

/// A log record, ready to export.
class LogData {
  LogData({
    required this.timeMicros,
    required this.severity,
    required this.body,
    required this.attributes,
    this.traceId,
    this.spanId,
  });

  final int timeMicros;
  final Severity severity;
  final String body;
  final Map<String, Object> attributes;
  final String? traceId;
  final String? spanId;

  Map<String, Object> toOtlp() => {
        'timeUnixNano': nanosString(timeMicros),
        'observedTimeUnixNano': nanosString(timeMicros),
        'severityNumber': severity.number,
        'severityText': severity.text,
        'body': {'stringValue': body},
        'attributes': keyValues(attributes),
        if (traceId != null) 'traceId': traceId!,
        if (spanId != null) 'spanId': spanId!,
      };
}

/// The instrumentation scope every record is reported under.
Map<String, Object> scope(String version) => {'name': 'zharp', 'version': version};

/// `ExportTraceServiceRequest` for one resource.
Map<String, Object> traceRequest(Map<String, Object> resource, List<SpanData> spans, String version) => {
      'resourceSpans': [
        {
          'resource': {'attributes': keyValues(resource)},
          'scopeSpans': [
            {
              'scope': scope(version),
              'spans': [for (final span in spans) span.toOtlp()],
            },
          ],
        },
      ],
    };

/// `ExportLogsServiceRequest` for one resource.
Map<String, Object> logsRequest(Map<String, Object> resource, List<LogData> logs, String version) => {
      'resourceLogs': [
        {
          'resource': {'attributes': keyValues(resource)},
          'scopeLogs': [
            {
              'scope': scope(version),
              'logRecords': [for (final log in logs) log.toOtlp()],
            },
          ],
        },
      ],
    };

/// Roughly how many bytes a record adds to a request, to keep requests well under the server's
/// 10 MB limit without encoding everything twice.
int estimateSize(Map<String, Object> otlp) => utf8.encode(jsonEncode(otlp)).length;
