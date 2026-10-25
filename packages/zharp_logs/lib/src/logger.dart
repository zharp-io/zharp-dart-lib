import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'env.dart';
import 'message.dart';
import 'platform.dart';
import 'transport.dart';

/// How bad a log is.
enum LogLevel { debug, info, warn, error, fatal }

/// How long a crashing process waits for its last logs to go out before it ends.
const Duration _fatalFlushTimeout = Duration(seconds: 2);

/// Logs kept while they wait to be sent. When the network is down for long, the oldest go first.
const int _maxQueued = 500;

/// Sends your app's logs to Zharp.
///
/// Call [init] once at startup, then log from anywhere:
///
/// ```dart
/// ZharpLogger.init(apiKey: 'your-ingest-only-key', service: 'checkout-api');
/// ZharpLogger.info('User signed in', {'userId': 42});
/// ```
///
/// Logs are queued and sent in batches; `error` and `fatal` are sent at once.
abstract final class ZharpLogger {
  static _Setup? _setup;
  static String? _sessionId;
  static Map<String, Object?>? _platformContext;
  static Map<String, Object?> _extraContext = {};
  static Map<String, Object?> _integrationContext = {};

  /// Start sending logs. Call once, as early as possible.
  ///
  /// Anything left out is read from `--dart-define`, then from the process environment (on a
  /// server or a CLI): `ZHARP_API_KEY`, `ZHARP_SERVICE` (then `OTEL_SERVICE_NAME`), `ZHARP_ENV`,
  /// `ZHARP_VERSION`, `ZHARP_SOURCE`, `ZHARP_ENDPOINT`, `ZHARP_CAPTURE_PRINT`. With no API key
  /// anywhere, nothing starts and a hint is printed. `ZHARP_DISABLED=true` turns this off.
  ///
  /// On success it prints one line:
  /// `[Zharp] Logging active — service "checkout-api", environment "production"`.
  ///
  /// Calling it again replaces the running setup; what the old one had queued is still sent,
  /// with its own key.
  ///
  /// - [service]: the name logs are filed under. Defaults to the `name` in the app's
  ///   pubspec.yaml when one can be found (`dart run`), else `unknown-service`.
  /// - [environment], [appVersion], [source]: tags every log carries. Not guessed when unset.
  /// - [capturePrint]: also send what the app `print`s, as `info` logs, inside [guard].
  ///   Off by default.
  /// - [httpClient]: the client requests go through; one is made when not given.
  static void init({
    String? apiKey,
    String? service,
    String? environment,
    String? appVersion,
    String? source,
    String? endpoint,
    Duration flushInterval = const Duration(seconds: 5),
    int maxBatchSize = 50,
    bool? capturePrint,
    http.Client? httpClient,
  }) {
    final previous = _setup;
    if (previous != null) {
      _setup = null;
      unawaited(previous.close());
    }

    if (disabledByEnv()) {
      announce('Logging disabled by ZHARP_DISABLED — nothing will be sent');
      return;
    }

    final key = pick([apiKey, envValue('ZHARP_API_KEY')]);
    if (key == null) {
      announce('No API key found — pass apiKey to ZharpLogger.init(), or set ZHARP_API_KEY');
      return;
    }

    var name = pick([service, envValue('ZHARP_SERVICE'), envValue('OTEL_SERVICE_NAME'), pubspecName()]);
    if (name == null) {
      // A warning, not an error: a missing name shouldn't stop the app, and the logs are still
      // worth having under a placeholder.
      announce("No service name — pass service to ZharpLogger.init() or set ZHARP_SERVICE. Using 'unknown-service'.");
      name = 'unknown-service';
    }

    final setup = _Setup(
      service: name,
      environment: pick([environment, envValue('ZHARP_ENV')]),
      appVersion: pick([appVersion, envValue('ZHARP_VERSION')]),
      source: pick([source, envValue('ZHARP_SOURCE')]),
      flushInterval: flushInterval,
      maxBatchSize: maxBatchSize < 1 ? 1 : maxBatchSize,
      capturePrint: capturePrint ?? flagOf(envValue('ZHARP_CAPTURE_PRINT')) ?? false,
      ownsClient: httpClient == null,
      transport: Transport(
        apiKey: key,
        endpoint: normalizeEndpoint(pick([endpoint, envValue('ZHARP_ENDPOINT')])),
        client: httpClient ?? createHttpClient(),
      ),
    );
    _setup = setup;
    announce('Logging active — ${describeTarget(setup.service, setup.environment)}'
        '${setup.capturePrint ? ', capturing print' : ''}');
  }

  /// Whether [init] succeeded and logs are being sent.
  static bool get isActive => _setup != null;

  /// The ID every log of this run carries, so one session's logs can be found together.
  static String get sessionId => _sessionId ??= _uuid();

  /// Start a new session ID, e.g. when a different user signs in.
  static void resetSessionId() => _sessionId = _uuid();

  /// Extra fields added to every log's `context`, e.g. a signed-in user's ID or the device
  /// model. Replaces what was set before; pass `{}` to clear it.
  static void setContext(Map<String, Object?> context) => _extraContext = toJsonMap(context);

  static void debug(Object? message, [Map<String, Object?>? metadata]) => log(LogLevel.debug, message, metadata: metadata);
  static void info(Object? message, [Map<String, Object?>? metadata]) => log(LogLevel.info, message, metadata: metadata);
  static void warn(Object? message, [Map<String, Object?>? metadata]) => log(LogLevel.warn, message, metadata: metadata);

  /// Logs at `error` and sends at once, so it isn't lost if the app dies right after.
  static void error(Object? message, [Map<String, Object?>? metadata]) => log(LogLevel.error, message, metadata: metadata);

  /// Logs at `fatal` and sends at once.
  static void fatal(Object? message, [Map<String, Object?>? metadata]) => log(LogLevel.fatal, message, metadata: metadata);

  /// Log at [level]. [service] files this one log under another service than the one set in
  /// [init]. Before [init] (or after a failed one) logs are dropped.
  static void log(LogLevel level, Object? message, {Map<String, Object?>? metadata, String? service}) {
    final setup = _setup;
    if (setup == null) return;
    setup.push(_entry(setup, level, message, metadata, service));
    if (level == LogLevel.error || level == LogLevel.fatal) unawaited(setup.flush());
  }

  /// Log a caught error with its stack, as an `error` log (or `fatal` when [fatal] is true).
  ///
  /// ```dart
  /// try { await charge(order); } catch (e, stack) { ZharpLogger.captureException(e, stack); }
  /// ```
  static void captureException(Object error, StackTrace? stack, {Map<String, Object?>? metadata, bool fatal = false}) {
    log(fatal ? LogLevel.fatal : LogLevel.error, error, metadata: {
      ...?metadata,
      'name': error.runtimeType.toString(),
      if (stack != null) 'stack': stack.toString(),
    });
  }

  /// Run [body] with uncaught errors captured — the Dart equivalent of an unhandled exception
  /// handler. Call [init] first.
  ///
  /// An uncaught error is logged with its stack and sent, then (on a server or CLI) printed and
  /// the process ends with exit code 1, as it would have without Zharp. Pass
  /// `exitOnError: false` to keep running instead. With `capturePrint`, what [body] prints is
  /// sent too.
  ///
  /// ```dart
  /// void main() {
  ///   ZharpLogger.init();
  ///   ZharpLogger.guard(() async {
  ///     await serve();
  ///   });
  /// }
  /// ```
  static Future<void> guard(FutureOr<void> Function() body, {bool exitOnError = true}) {
    final done = Completer<void>();
    var printing = false;
    runZonedGuarded(
      () async {
        try {
          await body();
        } finally {
          if (!done.isCompleted) done.complete();
        }
      },
      (error, stack) async {
        captureException(error, stack, metadata: {'type': 'uncaughtError'});
        if (!exitOnError || !canExitProcess) return;
        await flushAll().timeout(_fatalFlushTimeout, onTimeout: () {});
        exitWithError(error, stack);
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          parent.print(zone, line);
          final setup = _setup;
          // The SDK's own lines stay out, and a print made while one is being handled is not
          // captured again, so nothing here can feed itself.
          if (setup == null || !setup.capturePrint || printing || line.startsWith('[Zharp]')) return;
          printing = true;
          try {
            log(LogLevel.info, line, metadata: {'origin': 'print'});
          } finally {
            printing = false;
          }
        },
      ),
    );
    return done.future;
  }

  /// Send what is queued now, one batch. Normally not needed: logs go out every few seconds,
  /// and errors at once.
  static Future<void> flush() async => _setup?.flush();

  /// Send everything queued, and wait for sends already under way.
  static Future<void> flushAll() async => _setup?.flushAll();

  /// Send everything queued and stop. Logs after this are dropped until [init] is called again.
  static Future<void> close() async {
    final setup = _setup;
    _setup = null;
    await setup?.close();
  }

  static Map<String, Object?> _entry(
    _Setup setup,
    LogLevel level,
    Object? message,
    Map<String, Object?>? metadata,
    String? service,
  ) {
    final environment = setup.environment;
    return {
      'service': (service == null || service.trim().isEmpty) ? setup.service : service.trim(),
      'level': level.name,
      'message': toMessage(message),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      // The tags the log viewer filters by, top level where the backend reads them; absent
      // rather than empty when not configured.
      if (environment != null) 'environment': environment,
      if (setup.appVersion != null) 'version': setup.appVersion,
      if (setup.source != null) 'source': setup.source,
      'metadata': {
        // The caller's fields at the top; what the SDK adds under its own keys.
        ...toJsonMap(metadata),
        'sessionId': sessionId,
        if (environment != null) 'environment': environment,
        'context': {
          ...(_platformContext ??= runtimeContext()),
          ..._integrationContext,
          ..._extraContext,
          if (setup.appVersion != null) 'appVersion': setup.appVersion,
        },
      },
    };
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Context an integration (zharp_logs_flutter) adds to every log, kept apart from what the app
/// sets with [ZharpLogger.setContext] so neither replaces the other. Not part of the public API.
void setIntegrationContext(Map<String, Object?> context) => ZharpLogger._integrationContext = toJsonMap(context);

/// One running configuration: its queue, its transport and its timer.
class _Setup {
  _Setup({
    required this.service,
    required this.environment,
    required this.appVersion,
    required this.source,
    required this.flushInterval,
    required this.maxBatchSize,
    required this.capturePrint,
    required this.ownsClient,
    required this.transport,
  });

  final String service;
  final String? environment;
  final String? appVersion;
  final String? source;
  final Duration flushInterval;
  final int maxBatchSize;
  final bool capturePrint;
  final bool ownsClient;
  final Transport transport;

  final List<Map<String, Object?>> _queue = [];
  final Set<Future<void>> _sending = {};
  Timer? _timer;

  void push(Map<String, Object?> entry) {
    if (_queue.length >= _maxQueued) _queue.removeAt(0);
    _queue.add(entry);
    // A one-shot timer, armed only while something waits. A periodic one would keep a Dart
    // script running forever; this one lets it finish once the last logs are out.
    _timer ??= Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    if (_queue.isEmpty) return;
    final take = _queue.length < maxBatchSize ? _queue.length : maxBatchSize;
    final batch = _queue.sublist(0, take);
    _queue.removeRange(0, take);
    if (_queue.isNotEmpty) {
      _timer ??= Timer(flushInterval, () {
        _timer = null;
        unawaited(flush());
      });
    }
    final sent = transport.send(batch);
    _sending.add(sent);
    try {
      await sent;
    } finally {
      _sending.remove(sent);
    }
  }

  Future<void> flushAll() async {
    while (_queue.isNotEmpty) {
      await flush();
    }
    await Future.wait(_sending.toList());
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await flushAll();
    if (ownsClient) transport.client.close();
  }
}
