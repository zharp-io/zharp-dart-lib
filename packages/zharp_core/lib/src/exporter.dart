import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'otlp.dart';
import 'platform.dart';
import 'version.dart';

/// How a request went, as far as what to do next.
enum _Outcome { sent, dropped, retryNetwork, retryServer, rejected }

/// Sends spans to `{endpoint}/v1/traces` and logs to `{endpoint}/v1/logs` as OTLP/JSON.
///
/// - Records wait in memory and go out in batches: every [flushInterval], or as soon as
///   [maxBatchSize] are waiting. A request stays under [maxRequestBytes] before compression.
/// - Bodies are gzipped where the platform can (everywhere but the web).
/// - Network failures, 408, 429 and 5xx are retried with exponential backoff (honouring
///   `Retry-After`); while offline, records stay queued. Each queue holds at most [maxQueueSize]
///   records: when full, the oldest go first, so memory stays bounded however long the outage.
/// - 400 and other client errors drop the batch: sending it again won't help.
/// - 401/403 (a wrong, revoked or origin-restricted key) print one warning and stop sending;
///   batches are dropped, not kept, and one is tried again after [keyRetryDelay].
/// - Nothing here throws: every failure is caught.
class Exporter {
  Exporter({
    required this.key,
    required this.endpoint,
    required this.client,
    required this.resource,
    this.flushInterval = const Duration(seconds: 5),
    this.maxBatchSize = 100,
    this.maxQueueSize = 1000,
    this.maxRequestBytes = 1000000,
    this.timeout = const Duration(seconds: 30),
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(minutes: 5),
    this.keyRetryDelay = const Duration(hours: 1),
    this.compress = true,
    void Function(String message)? warn,
    void Function(String message)? debug,
    DateTime Function()? clock,
  })  : _warn = warn ?? ((_) {}),
        _debug = debug ?? ((_) {}),
        _clock = clock ?? DateTime.now {
    _spans = _Queue<SpanData>(this, 'traces', (spans) => traceRequest(resource, spans, sdkVersion));
    _logs = _Queue<LogData>(this, 'logs', (logs) => logsRequest(resource, logs, sdkVersion));
  }

  final String key;

  /// The base endpoint, without a trailing slash, e.g. `https://api.zharp.io/api/v1/otlp`.
  final String endpoint;
  final http.Client client;
  final Map<String, Object> resource;
  final Duration flushInterval;
  final int maxBatchSize;
  final int maxQueueSize;
  final int maxRequestBytes;
  final Duration timeout;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Duration keyRetryDelay;
  final bool compress;
  final void Function(String message) _warn;
  final void Function(String message) _debug;
  final DateTime Function() _clock;

  late final _Queue<SpanData> _spans;
  late final _Queue<LogData> _logs;

  /// While the key is rejected: when one batch may be tried again.
  DateTime? _keyRetryAt;
  bool _closed = false;

  /// Records dropped because a queue was full, since start. For diagnostics and tests.
  int get dropped => _spans.dropped + _logs.dropped;

  /// Records waiting to be sent.
  int get pending => _spans.length + _logs.length;

  void addSpan(SpanData span) {
    if (!_closed) _spans.add(span);
  }

  void addLog(LogData log) {
    if (!_closed) _logs.add(log);
  }

  /// Send everything queued now, ignoring any backoff wait once, and wait for it. Used when the
  /// app goes to the background and before exit. Records that still can't be sent stay queued.
  Future<void> flush() async {
    await Future.wait([_spans.drain(force: true), _logs.drain(force: true)]);
  }

  /// Flush, then stop accepting records.
  Future<void> shutdown({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      await flush().timeout(timeout);
    } catch (_) {
      // Whatever didn't make it in time is dropped.
    }
    _closed = true;
    _spans.cancel();
    _logs.cancel();
  }

  Future<_Outcome> _post(String path, Map<String, Object> request) async {
    final retryAt = _keyRetryAt;
    if (retryAt != null && _clock().isBefore(retryAt)) return _Outcome.rejected;
    try {
      final json = utf8.encode(jsonEncode(request));
      final gzipped = compress ? gzipBytes(json) : null;
      final response = await client
          .post(
            Uri.parse('$endpoint/v1/$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
              if (gzipped != null) 'Content-Encoding': 'gzip',
            },
            body: gzipped ?? json,
          )
          .timeout(timeout);
      return _outcomeOf(response, path);
    } catch (error) {
      _debug('Sending $path failed ($error); will retry');
      if (retryAt != null) _keyRetryAt = _clock().add(keyRetryDelay);
      return _Outcome.retryNetwork;
    }
  }

  Duration? _retryAfter;

  _Outcome _outcomeOf(http.Response response, String path) {
    final status = response.statusCode;
    final wasRejected = _keyRetryAt != null;
    if (status == 401 || status == 403) {
      if (!wasRejected) {
        _warn('Zharp rejected the key (HTTP $status${_reason(response)}) — telemetry is not being sent. '
            'Check the key passed to Zharp.init, and its allowed origins.');
      }
      _keyRetryAt = _clock().add(keyRetryDelay);
      return _Outcome.rejected;
    }
    if (wasRejected) {
      if (status >= 200 && status < 300) {
        _keyRetryAt = null;
        _warn('Zharp accepted the key again — telemetry is being sent.');
      } else {
        _keyRetryAt = _clock().add(keyRetryDelay);
      }
    }
    if (status >= 200 && status < 300) return _Outcome.sent;
    if (status == 408 || status == 429 || status >= 500) {
      final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
      _retryAfter = seconds != null && seconds > 0 ? Duration(seconds: seconds) : null;
      _debug('Sending $path got HTTP $status; will retry');
      return _Outcome.retryServer;
    }
    _debug('Zharp refused a $path batch (HTTP $status${_reason(response)}); dropped');
    return _Outcome.dropped;
  }

  String _reason(http.Response response) {
    final body = response.body.trim();
    if (body.isEmpty || body == '{}') return '';
    return ': ${body.length > 200 ? body.substring(0, 200) : body}';
  }
}

/// One signal's queue — spans or logs — and its own retry state.
class _Queue<T> {
  _Queue(this.exporter, this.path, this.build);

  final Exporter exporter;
  final String path;
  final Map<String, Object> Function(List<T> records) build;

  final List<T> _items = [];
  final List<int> _sizes = [];
  Timer? _timer;
  Future<void>? _running;
  DateTime? _retryAt;
  int _failures = 0;
  int _serverFailures = 0;
  int dropped = 0;
  final Random _jitter = Random();

  int get length => _items.length;

  void add(T record) {
    try {
      _push(record, _sizeOf(record));
    } catch (_) {
      // A record that can't be encoded is dropped rather than poisoning the batch.
      return;
    }
    if (_items.length >= exporter.maxBatchSize && _retryAt == null) {
      _timer?.cancel();
      _timer = null;
      scheduleMicrotask(() => drain());
    } else {
      _arm(exporter.flushInterval);
    }
  }

  int _sizeOf(T record) {
    final otlp = record is SpanData ? record.toOtlp() : (record as LogData).toOtlp();
    return estimateSize(otlp);
  }

  void _push(T record, int size) {
    while (_items.length >= exporter.maxQueueSize) {
      _items.removeAt(0);
      _sizes.removeAt(0);
      dropped++;
    }
    _items.add(record);
    _sizes.add(size);
  }

  /// A one-shot timer, armed only while something waits: a periodic one would keep a Dart
  /// program alive forever.
  void _arm(Duration delay) {
    if (_timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(drain());
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Send what is queued, batch after batch, one request at a time.
  Future<void> drain({bool force = false}) {
    final previous = _running;
    final next = () async {
      if (previous != null) await previous;
      await _drain(force);
    }();
    _running = next;
    return next.whenComplete(() {
      if (identical(_running, next)) _running = null;
    });
  }

  Future<void> _drain(bool force) async {
    while (_items.isNotEmpty) {
      final retryAt = _retryAt;
      if (!force && retryAt != null && exporter._clock().isBefore(retryAt)) {
        _arm(retryAt.difference(exporter._clock()));
        return;
      }
      // Take what fits in one request.
      var count = 0;
      var bytes = 0;
      while (count < _items.length && count < exporter.maxBatchSize) {
        if (count > 0 && bytes + _sizes[count] > exporter.maxRequestBytes) break;
        bytes += _sizes[count];
        count++;
      }
      final batch = _items.sublist(0, count);
      final sizes = _sizes.sublist(0, count);
      _items.removeRange(0, count);
      _sizes.removeRange(0, count);

      final outcome = await exporter._post(path, build(batch));
      switch (outcome) {
        case _Outcome.sent:
          _failures = 0;
          _serverFailures = 0;
          _retryAt = null;
        case _Outcome.dropped:
          _serverFailures = 0;
          _retryAt = null;
        case _Outcome.rejected:
          // Dropped: a rejected key won't start working on its own soon, and keeping
          // everything would grow without bound. Whatever else is queued goes the same way
          // until the key is tried again.
          dropped += batch.length + _items.length;
          _items.clear();
          _sizes.clear();
          return;
        case _Outcome.retryNetwork:
        case _Outcome.retryServer:
          _failures++;
          // A server error that keeps happening is likely about this batch; after a few tries
          // it goes. A network failure (offline) doesn't count: the batch waits for the network.
          if (outcome == _Outcome.retryServer) _serverFailures++;
          if (_serverFailures >= 5) {
            dropped += batch.length;
            _serverFailures = 0;
          } else {
            // Back at the front, oldest first, within the cap.
            _items.insertAll(0, batch);
            _sizes.insertAll(0, sizes);
            while (_items.length > exporter.maxQueueSize) {
              _items.removeAt(0);
              _sizes.removeAt(0);
              dropped++;
            }
          }
          final wait = exporter._retryAfter ?? _backoff();
          exporter._retryAfter = null;
          _retryAt = exporter._clock().add(wait);
          _arm(wait);
          return;
      }
      force = false;
    }
  }

  Duration _backoff() {
    final base = exporter.minBackoff.inMilliseconds * pow(2, min(_failures - 1, 20));
    final capped = min(base.toDouble(), exporter.maxBackoff.inMilliseconds.toDouble());
    // ±20% so many devices coming back online don't retry in step.
    final jittered = capped * (0.8 + _jitter.nextDouble() * 0.4);
    return Duration(milliseconds: jittered.round());
  }
}
