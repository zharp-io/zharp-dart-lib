import 'dart:async';

import 'ids.dart';
import 'otlp.dart';
import 'span.dart';

/// Starts spans, decides which traces are kept, and knows which span is current.
///
/// The current span is, in order: the one set for the running zone (inside `Zharp.startSpan`),
/// then the open screen-view span. So a request made while a screen is loading joins that
/// screen's trace without any wiring.
class Tracer {
  Tracer({
    required this.sampleRate,
    required this.contextAttributes,
    required this.export,
    DateTime Function()? clock,
    double Function()? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? randomUnit;

  final double sampleRate;

  /// Session, user and tag attributes, added to every span when it starts.
  final Map<String, Object> Function() contextAttributes;
  final void Function(ZharpSpan span) export;
  final DateTime Function() _clock;
  final double Function() _random;

  IdleSpan? _ambient;
  final Map<String, IdleSpan> _idleBySpanId = {};

  /// The span new work belongs to, or null.
  ZharpSpan? get current {
    final fromZone = zoneSpan();
    if (fromZone != null) return fromZone;
    final ambient = _ambient;
    return ambient != null && !ambient.span.isEnded ? ambient.span : null;
  }

  /// Start a span. Its parent is [parent], else the [current] span — unless [root] is true.
  ZharpSpan start(
    String name, {
    SpanKind kind = SpanKind.internal,
    ZharpSpan? parent,
    bool root = false,
    Map<String, Object?>? attributes,
    DateTime? startTime,
    ({String traceId, String spanId, bool sampled})? remoteParent,
  }) {
    final parentSpan = root || remoteParent != null ? null : (parent ?? current);
    // A caller's decision (its traceparent's flag) is kept, as a parent's is.
    final sampled = remoteParent?.sampled ??
        parentSpan?.sampled ??
        (sampleRate >= 1 || (sampleRate > 0 && _random() < sampleRate));
    final ids = idsFor(parentSpan);
    final span = ZharpSpan.internal(
      traceId: remoteParent?.traceId ?? ids.traceId,
      spanId: ids.spanId,
      parentSpanId: remoteParent?.spanId ?? parentSpan?.spanId,
      name: name.isEmpty ? '(unnamed)' : name,
      kind: kind,
      sampled: sampled,
      startMicros: (startTime ?? _clock()).microsecondsSinceEpoch,
      attributes: {...contextAttributes(), ...sanitizeAttributes(attributes)},
      onEnd: _ended,
      clock: _clock,
    );
    if (parentSpan != null) _idleBySpanId[parentSpan.spanId]?.childStarted(span);
    return span;
  }

  void _ended(ZharpSpan span) {
    _idleBySpanId.values.where((idle) => idle.hasChild(span)).toList().forEach((idle) => idle.childEnded(span));
    if (span.sampled) export(span);
  }

  /// Run [body] with [span] current, so spans started inside — including after `await` — are
  /// its children.
  R runWith<R>(ZharpSpan span, R Function() body) => runZoned(body, zoneValues: {spanZoneKey: span});

  /// Start a root span that ends by itself once the work it started has finished: it waits for
  /// its children (and [hold]s), then [idleTimeout] more without new ones, at most [maxDuration].
  /// It becomes the ambient current span, replacing (and ending) any previous one.
  IdleSpan startIdle(
    String name, {
    required Duration idleTimeout,
    required Duration maxDuration,
    Map<String, Object?>? attributes,
  }) {
    endIdle();
    final span = start(name, root: true, attributes: attributes);
    late final IdleSpan idle;
    idle = IdleSpan._(span, idleTimeout, maxDuration, _clock, () {
      _idleBySpanId.remove(span.spanId);
      if (identical(_ambient, idle)) _ambient = null;
    });
    _ambient = idle;
    _idleBySpanId[span.spanId] = idle;
    idle._armIdle();
    return idle;
  }

  /// End the ambient span now (a new screen is replacing it).
  void endIdle() => _ambient?.finish(reason: 'replaced');

  /// The ambient screen-view span, while it is open.
  IdleSpan? get ambient => _ambient;
}

/// A span that ends itself when its work is done. See [Tracer.startIdle].
class IdleSpan {
  IdleSpan._(this.span, this.idleTimeout, this.maxDuration, this._clock, this._onFinish) {
    _maxTimer = Timer(maxDuration, () => finish(reason: 'max_duration'));
    _lastActivityEnd = DateTime.fromMicrosecondsSinceEpoch(span.startMicros);
  }

  final ZharpSpan span;
  final Duration idleTimeout;
  final Duration maxDuration;
  final DateTime Function() _clock;
  final void Function() _onFinish;

  final Set<String> _children = {};
  int _holds = 0;
  Timer? _idleTimer;
  Timer? _maxTimer;
  DateTime? _lastActivityEnd;

  bool hasChild(ZharpSpan child) => _children.contains(child.spanId);

  void childStarted(ZharpSpan child) {
    if (span.isEnded) return;
    _children.add(child.spanId);
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void childEnded(ZharpSpan child) {
    if (!_children.remove(child.spanId)) return;
    _activityEnded();
  }

  /// Keep the span open until [release] is called — e.g. until the screen's first frame is drawn.
  /// Returns the release function; calling it more than once does nothing.
  void Function() hold() {
    if (span.isEnded) return () {};
    _holds++;
    _idleTimer?.cancel();
    _idleTimer = null;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _holds--;
      _activityEnded();
    };
  }

  void _activityEnded() {
    _lastActivityEnd = _clock();
    _armIdle();
  }

  void _armIdle() {
    if (span.isEnded || _children.isNotEmpty || _holds > 0) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => finish(reason: 'idle'));
  }

  /// End now. The span's end is the moment its last piece of work finished — not the idle wait
  /// after it — unless work is still running.
  void finish({required String reason}) {
    if (span.isEnded) return;
    _idleTimer?.cancel();
    _maxTimer?.cancel();
    final busy = _children.isNotEmpty || _holds > 0;
    if (reason != 'idle') span.setAttribute('zharp.span.end_reason', reason);
    span.end(busy ? null : _lastActivityEnd);
    _onFinish();
  }
}
