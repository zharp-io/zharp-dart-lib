import 'dart:async';

import 'errors.dart';
import 'exporter.dart';
import 'otlp.dart';
import 'options.dart';
import 'output.dart';
import 'platform.dart';
import 'propagation.dart';
import 'session.dart';
import 'span.dart';
import 'tracer.dart';
import 'version.dart';

/// The user `setUser` identified.
class ZharpUser {
  const ZharpUser({required this.id, this.email, this.name});

  final String id;
  final String? email;
  final String? name;
}

/// The running SDK: what `Zharp` (zharp_flutter) and the HTTP integrations talk to.
///
/// Platform integrations create one with [ZharpCore.start] and then hook the platform's error,
/// lifecycle and navigation events into it. Every public method catches its own failures: the
/// SDK never throws into the app.
class ZharpCore {
  ZharpCore._(this.options, this.resource, this._exporter, this.session, this._ownsClient, this._clock) {
    tracer = Tracer(
      // Logs-only mode: nothing that reaches the tracer directly is exported either.
      sampleRate: options.tracing ? options.sampleRate.clamp(0.0, 1.0).toDouble() : 0.0,
      contextAttributes: () => contextAttributes(),
      export: (span) => _exporter.addSpan(span.toData()),
      clock: _clock,
    );
    log = ZharpLog._(this);
  }

  /// The SDK that is running, or null before start (or when disabled).
  static ZharpCore? get instance => _instance;
  static ZharpCore? _instance;

  /// Start the SDK and make it [instance], replacing (and flushing) one already running.
  ///
  /// [resourceAttributes] are added to the resource — the device, OS and app context a platform
  /// integration knows. [defaultRelease] is used when the options set no release (the app's
  /// version, as the platform reports it). Returns null when [ZharpOptions.enabled] is false or the key is missing.
  static ZharpCore? start(
    ZharpOptions options, {
    Map<String, Object?> resourceAttributes = const {},
    String? defaultRelease,
    DateTime Function()? clock,
    bool stampLines = true,
  }) {
    final previous = _instance;
    _instance = null;
    if (previous != null) unawaited(previous.close());

    if (!options.enabled) {
      if (options.debug) _print('Disabled by ZharpOptions.enabled — nothing will be sent');
      return null;
    }
    final key = options.key.trim();
    if (key.isEmpty) {
      _print('No key passed to Zharp.init — nothing will be sent. Copy it from the app\'s Setup page.');
      return null;
    }

    final resource = <String, Object>{
      ...platformAttributes(),
      ...sanitizeAttributes(resourceAttributes),
      'service.name': _nonBlank(options.service) ?? 'unknown_service:dart',
      if ((_nonBlank(options.release) ?? _nonBlank(defaultRelease)) != null)
        'service.version': (_nonBlank(options.release) ?? _nonBlank(defaultRelease))!,
      if (_nonBlank(options.environment) != null) 'deployment.environment.name': _nonBlank(options.environment)!,
      'telemetry.sdk.name': 'zharp',
      'telemetry.sdk.language': 'dart',
      'telemetry.sdk.version': sdkVersion,
    };
    final now = clock ?? DateTime.now;
    final ownsClient = options.httpClient == null;
    final exporter = Exporter(
      key: key,
      endpoint: normalizeEndpoint(options.endpoint),
      client: options.httpClient ?? createHttpClient(),
      resource: resource,
      flushInterval: options.flushInterval,
      maxBatchSize: options.maxBatchSize < 1 ? 1 : options.maxBatchSize,
      maxQueueSize: options.maxQueueSize < 1 ? 1 : options.maxQueueSize,
      warn: _print,
      debug: options.debug ? _print : null,
      clock: now,
    );
    final core = ZharpCore._(
      options,
      resource,
      exporter,
      SessionManager(timeout: options.sessionTimeout, clock: now),
      ownsClient,
      now,
    );
    core.stampsLines = stampLines &&
        canStampOutput &&
        switchOn(options.logCorrelation, 'ZHARP_LOG_CORRELATION', const String.fromEnvironment('ZHARP_LOG_CORRELATION'),
            fallback: true);
    _instance = core;
    if (core.capturesOutput) core._stopLogging = captureLoggingRecords();
    if (options.debug) {
      _print('Started — service "${resource['service.name']}", sending to ${exporter.endpoint}');
    }
    return core;
  }

  final ZharpOptions options;

  /// Resource attributes sent with every batch.
  final Map<String, Object> resource;
  final Exporter _exporter;
  final SessionManager session;
  final bool _ownsClient;
  final DateTime Function() _clock;

  late final Tracer tracer;
  late final ZharpLog log;

  /// Whether what the app logs and prints is sent ([ZharpOptions.logs] or `ZHARP_LOGS`; off by
  /// default).
  late final bool sendsLogs =
      switchOn(options.logs, 'ZHARP_LOGS', const String.fromEnvironment('ZHARP_LOGS'), fallback: false);

  /// Whether what the app prints is sent as logs: [sendsLogs], and [ZharpOptions.captureOutput]
  /// unless `ZHARP_CAPTURE_OUTPUT=false`.
  late final bool capturesOutput = sendsLogs && options.captureOutput && outputCaptureAllowed();

  /// Whether lines printed inside [run] during a span end with its trace_id and span_id
  /// ([ZharpOptions.logCorrelation]; Dart servers and tools only).
  bool stampsLines = false;
  void Function()? _stopLogging;

  /// Run [body] — a Dart server or command-line tool — where every line printed (`print`,
  /// `stdout`, `stderr`) during a span ends with its `trace_id` and `span_id`
  /// ([ZharpOptions.logCorrelation]), and, with [ZharpOptions.logs] on, is also sent as a log.
  /// Errors and the return value are [body]'s own. Start Zharp inside it or before it:
  ///
  /// ```dart
  /// void main() => ZharpCore.run(() async {
  ///   ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'api'));
  ///   await serve();
  /// });
  /// ```
  static R run<R>(R Function() body) => runCapturingOutput(body);

  ZharpUser? _user;
  final Map<String, Object> _tags = {};
  String? _screen;
  bool _closed = false;

  /// The base endpoint telemetry goes to; requests to it are never traced.
  String get endpoint => _exporter.endpoint;

  /// Records queued and not yet sent.
  int get pending => _exporter.pending;

  ZharpUser? get user => _user;

  /// Add context a platform learns after start — device details from native code — to the
  /// resource. Batches sent from now on carry it. What the options set (service, environment,
  /// release) and the SDK's own attributes are kept; [defaultRelease] applies only when the
  /// options set no release.
  void updateResource(Map<String, Object?> attributes, {String? defaultRelease}) {
    _guard(() {
      final clean = sanitizeAttributes(attributes)
        ..removeWhere((key, _) =>
            key == 'service.name' ||
            key == 'service.version' ||
            key.startsWith('deployment.environment') ||
            key.startsWith('telemetry.sdk.'));
      resource.addAll(clean);
      final release = _nonBlank(defaultRelease);
      if (_nonBlank(options.release) == null && release != null) resource['service.version'] = release;
    });
  }

  // ─── Context ───────────────────────────────────────────────────────────────

  /// Identify the signed-in user. `id` becomes `enduser.id`; email and name `enduser.email` and
  /// `enduser.name`.
  void setUser({required String id, String? email, String? name}) {
    _guard(() {
      final trimmed = id.trim();
      if (trimmed.isEmpty) return clearUser();
      _user = ZharpUser(id: trimmed, email: _nonBlank(email), name: _nonBlank(name));
    });
  }

  /// Forget the user (sign-out). Starts a new session, so the next person's activity isn't
  /// joined to the last one's.
  void clearUser() {
    _guard(() {
      _user = null;
      session.reset();
    });
  }

  /// An attribute added to every span, log and error from now on. A null value removes it.
  void setTag(String key, Object? value) {
    _guard(() {
      if (value == null) {
        _tags.remove(key);
      } else {
        _tags.addAll(sanitizeAttributes({key: value}));
      }
    });
  }

  /// The screen the user is on, as `app.screen.name` on everything recorded.
  void setScreen(String? name) => _screen = _nonBlank(name);
  String? get screen => _screen;

  /// The attributes on every span and log record: tags, the user, the session and the screen.
  Map<String, Object> contextAttributes() {
    final user = _user;
    return {
      ..._tags,
      'session.id': session.touch(),
      if (user != null) 'enduser.id': user.id,
      if (user?.email != null) 'enduser.email': user!.email!,
      if (user?.name != null) 'enduser.name': user!.name!,
      if (_screen != null) 'app.screen.name': _screen!,
    };
  }

  // ─── Errors ────────────────────────────────────────────────────────────────

  final Map<String, DateTime> _recentErrors = {};

  /// Report an error. [handled] is true for errors the app caught (`captureError`), false for
  /// uncaught ones. Sent as an ERROR log record with `exception.*` attributes — always sent,
  /// whatever the trace sample rate — tied to the current span's trace when there is one.
  void captureError(
    Object error, {
    StackTrace? stackTrace,
    bool handled = true,
    Map<String, Object?>? attributes,
    Severity severity = Severity.error,
  }) {
    _guard(() {
      if (wasReported(error)) return;
      final exception = describeError(error, stackTrace);
      if (_isRepeat(exception)) return;
      markReported(error);
      log._emit(
        severity,
        exception.message.isEmpty ? exception.type : exception.message,
        {...?attributes, ...exception.attributes(handled: handled)},
      );
    });
  }

  /// The same error from the same place reported again within a second — a widget failing on
  /// every frame — is skipped.
  bool _isRepeat(ExceptionDescription exception) {
    final now = _clock();
    // The error's first line and its first frame (not an obfuscated stack's header lines).
    final key = '${exception.stacktrace.split('\n').first}\n${exception.firstFrame}';
    _recentErrors.removeWhere((_, at) => now.difference(at) > const Duration(seconds: 1));
    if (_recentErrors.containsKey(key)) return true;
    if (_recentErrors.length < 100) _recentErrors[key] = now;
    return false;
  }

  // ─── Spans ─────────────────────────────────────────────────────────────────

  /// Run [body] inside a new span, which ends when [body] returns (or its Future completes).
  /// Spans and requests started inside become its children. If [body] throws, the error is
  /// recorded on the span as unhandled and rethrown.
  T startSpan<T>(
    String name,
    T Function(ZharpSpan span) body, {
    Map<String, Object?>? attributes,
    SpanKind kind = SpanKind.internal,
  }) {
    // Logs-only mode: the callback runs, no span is made.
    if (!options.tracing) return body(_noopSpan(name));
    final ZharpSpan span;
    try {
      span = tracer.start(name, kind: kind, attributes: attributes);
    } catch (_) {
      return body(_noopSpan(name));
    }
    final T result;
    try {
      result = tracer.runWith(span, () => body(span));
    } catch (error, stack) {
      _fail(span, error, stack);
      rethrow;
    }
    if (result is Future) {
      // Watch the Future on the side and hand back the very same one, so its type and its
      // error stay the caller's.
      result.then((_) => span.end(), onError: (Object error, StackTrace stack) => _fail(span, error, stack));
      return result;
    }
    span.end();
    return result;
  }

  void _fail(ZharpSpan span, Object error, StackTrace stack) {
    if (!wasReported(error)) span.recordException(error, stackTrace: stack, handled: false);
    span.setError();
    span.end();
  }

  ZharpSpan _noopSpan(String name) => ZharpSpan.internal(
        traceId: '0' * 32,
        spanId: '0' * 16,
        parentSpanId: null,
        name: name,
        kind: SpanKind.internal,
        sampled: false,
        startMicros: 0,
        attributes: {},
        onEnd: (_) {},
        clock: _clock,
      );

  /// The `traceparent` and `baggage` headers for a request to [url] made under [span], or an
  /// empty map when [url] isn't in `tracingOrigins` or is Zharp's own endpoint.
  Map<String, String> propagationHeaders(Uri url, ZharpSpan span, {String? existingBaggage}) {
    try {
      if (!options.tracing || isOwnEndpoint(url) || !shouldPropagate(url, options.tracingOrigins)) return const {};
      final baggage = mergeBaggage(existingBaggage, {
        'session.id': session.id,
        'enduser.id': _user?.id,
      });
      return {
        'traceparent': span.traceparent,
        if (baggage.isNotEmpty) 'baggage': baggage,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Whether [url] is where telemetry is sent — requests there are never traced.
  bool isOwnEndpoint(Uri url) {
    try {
      final own = Uri.parse(_exporter.endpoint);
      return url.host == own.host && url.port == own.port && url.path.startsWith(own.path);
    } catch (_) {
      return false;
    }
  }

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  /// The app went to the background: send what's queued (it may be killed without warning).
  Future<void> onBackground() async {
    session.background();
    if (options.flushOnPause) await flush();
  }

  /// The app came back: a new session if it was away for `sessionTimeout`.
  void onForeground() => _guard(session.foreground);

  /// Send everything queued now.
  Future<void> flush() async {
    try {
      flushCapturedOutput();
      await _exporter.flush();
    } catch (_) {}
  }

  /// Flush and stop. Records after this are dropped.
  Future<void> close({Duration timeout = const Duration(seconds: 5)}) async {
    if (_closed) return;
    _closed = true;
    try {
      flushCapturedOutput();
      _stopLogging?.call();
    } catch (_) {}
    if (identical(_instance, this)) _instance = null;
    try {
      tracer.endIdle();
      await _exporter.shutdown(timeout: timeout);
      if (_ownsClient) _exporter.client.close();
    } catch (_) {}
  }

  void _guard(void Function() body) {
    try {
      body();
    } catch (error) {
      if (options.debug) _print('Internal error: $error');
    }
  }
}

/// `Zharp.log.info('Checkout opened', {'items': 3})`: OTLP log records tied to the current
/// trace, with the session, user and tags.
class ZharpLog {
  ZharpLog._(this._core);

  final ZharpCore _core;

  void trace(Object? message, [Map<String, Object?>? attributes]) => _emit(Severity.trace, message, attributes);
  void debug(Object? message, [Map<String, Object?>? attributes]) => _emit(Severity.debug, message, attributes);
  void info(Object? message, [Map<String, Object?>? attributes]) => _emit(Severity.info, message, attributes);
  void warn(Object? message, [Map<String, Object?>? attributes]) => _emit(Severity.warn, message, attributes);

  /// An error log. When [message] is itself an error (`Zharp.log.error(e)`), it is also reported
  /// as one, with its stack: the same as `Zharp.captureError(e)`.
  void error(Object? message, [Map<String, Object?>? attributes]) {
    if (message is Error || message is Exception) {
      _core.captureError(message!, attributes: attributes);
      return;
    }
    _emit(Severity.error, message, attributes);
  }

  void fatal(Object? message, [Map<String, Object?>? attributes]) => _emit(Severity.fatal, message, attributes);

  void _emit(Severity severity, Object? message, Map<String, Object?>? attributes) {
    try {
      if (_core._closed) return;
      final body = _bodyOf(message);
      _add(severity, body, attributes, _core.tracer.current);
      // If the app prints it too, that copy isn't sent again.
      rememberSent(body);
    } catch (_) {
      // Never into the host app.
    }
  }

  /// A record from one of the output captures (`package:logging`, `print`, `debugPrint`,
  /// stdout), in [span] — the span current where it was written.
  void emitCaptured(Severity severity, String body, Map<String, Object?> attributes, {ZharpSpan? span}) {
    try {
      if (_core._closed) return;
      _add(severity, body, attributes, span);
    } catch (_) {}
  }

  void _add(Severity severity, String body, Map<String, Object?>? attributes, ZharpSpan? span) {
    _core._exporter.addLog(LogData(
      timeMicros: _core._clock().microsecondsSinceEpoch,
      severity: severity,
      body: body,
      attributes: {..._core.contextAttributes(), ...sanitizeAttributes(attributes)},
      traceId: span?.traceId,
      spanId: span?.spanId,
    ));
  }

  String _bodyOf(Object? message) {
    if (message == null) return '';
    try {
      return message is String ? message : message.toString();
    } catch (_) {
      return '<${message.runtimeType}>';
    }
  }
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The endpoint without trailing slashes.
String normalizeEndpoint(String? endpoint) => (_nonBlank(endpoint) ?? defaultEndpoint).replaceAll(RegExp(r'/+$'), '');

void _print(String message) {
  // ignore: avoid_print
  print('[Zharp] $message');
}
