import 'dart:async';

import 'errors.dart';
import 'ids.dart';
import 'otlp.dart';
import 'propagation.dart';

/// One timed operation in a trace: a screen view, an HTTP request, or work you wrap with
/// `Zharp.startSpan`.
///
/// Every method is safe to call at any time — after [end], calls are ignored.
class ZharpSpan {
  ZharpSpan.internal({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required String name,
    required this.kind,
    required this.sampled,
    required int startMicros,
    required Map<String, Object> attributes,
    required void Function(ZharpSpan span) onEnd,
    required DateTime Function() clock,
  })  : _name = name,
        _startMicros = startMicros,
        _attributes = attributes,
        _onEnd = onEnd,
        _clock = clock;

  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final SpanKind kind;

  /// Whether this span's trace is exported. Unsampled spans still propagate their trace ID.
  final bool sampled;

  String _name;
  final int _startMicros;
  final Map<String, Object> _attributes;
  final List<SpanEventData> _events = [];
  SpanStatusCode _status = SpanStatusCode.unset;
  String? _statusMessage;
  int? _endMicros;
  final void Function(ZharpSpan span) _onEnd;
  final DateTime Function() _clock;

  String get name => _name;
  bool get isEnded => _endMicros != null;
  int get startMicros => _startMicros;
  int? get endMicros => _endMicros;
  SpanStatusCode get status => _status;

  /// A copy of the attributes set so far.
  Map<String, Object> get attributes => Map.unmodifiable(_attributes);

  /// The `traceparent` header value that makes a downstream service continue this trace.
  String get traceparent => formatTraceparent(traceId, spanId, sampled: sampled);

  void updateName(String name) {
    if (!isEnded && name.isNotEmpty) _name = name;
  }

  void setAttribute(String key, Object? value) {
    if (isEnded) return;
    final clean = sanitizeAttributes({key: value});
    if (clean.isEmpty) {
      _attributes.remove(key);
    } else {
      _attributes.addAll(clean);
    }
  }

  void setAttributes(Map<String, Object?> attributes) {
    if (!isEnded) _attributes.addAll(sanitizeAttributes(attributes));
  }

  void addEvent(String name, [Map<String, Object?>? attributes]) {
    if (isEnded) return;
    _events.add(SpanEventData(name, _clock().microsecondsSinceEpoch, sanitizeAttributes(attributes)));
  }

  /// Mark the span failed. The message shows next to it in the trace view.
  void setError([String? message]) {
    if (isEnded) return;
    _status = SpanStatusCode.error;
    _statusMessage = message;
  }

  void setOk() {
    if (isEnded) return;
    _status = SpanStatusCode.ok;
    _statusMessage = null;
  }

  /// Record [error] on this span as an `exception` event — Zharp files it as an error event and
  /// groups it into an issue — and mark the span failed.
  ///
  /// [handled]: whether the app dealt with it (it won't crash or reach the user as a failure).
  void recordException(Object error, {StackTrace? stackTrace, bool handled = true, Map<String, Object?>? attributes}) {
    if (isEnded) return;
    final exception = describeError(error, stackTrace);
    _events.add(SpanEventData('exception', _clock().microsecondsSinceEpoch, {
      ...sanitizeAttributes(attributes),
      ...exception.attributes(handled: handled),
    }));
    setError(exception.message);
    markReported(error);
  }

  /// End the span now, or at [endTime]. Only the first call counts.
  void end([DateTime? endTime]) {
    if (isEnded) return;
    final micros = (endTime ?? _clock()).microsecondsSinceEpoch;
    _endMicros = micros < _startMicros ? _startMicros : micros;
    try {
      _onEnd(this);
    } catch (_) {
      // Never into the host app.
    }
  }

  SpanData toData() => SpanData(
        traceId: traceId,
        spanId: spanId,
        parentSpanId: parentSpanId,
        name: _name,
        kind: kind,
        startMicros: _startMicros,
        endMicros: _endMicros ?? _clock().microsecondsSinceEpoch,
        attributes: Map.of(_attributes),
        events: List.of(_events),
        statusCode: _status,
        statusMessage: _statusMessage,
      );
}

/// The zone key under which the active span lives, so work started inside `Zharp.startSpan`
/// (including across `await`) becomes its child.
final Object spanZoneKey = Object();

/// The span active in the current zone, if any.
ZharpSpan? zoneSpan() {
  final value = Zone.current[spanZoneKey];
  return value is ZharpSpan ? value : null;
}

/// A new span ID / trace ID pair for a child of [parent], or a new trace.
({String traceId, String spanId}) idsFor(ZharpSpan? parent) =>
    (traceId: parent?.traceId ?? newTraceId(), spanId: newSpanId());
