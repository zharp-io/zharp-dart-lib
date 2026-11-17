import 'package:http/http.dart' as http;

import 'bodies.dart';

/// Where telemetry goes unless `endpoint` says otherwise.
const String defaultEndpoint = 'https://api.zharp.io/api/v1/otlp';

/// How Zharp is set up. Only [key] is required.
class ZharpOptions {
  const ZharpOptions({
    required this.key,
    this.service,
    this.environment,
    this.release,
    this.endpoint,
    this.tracing = true,
    this.tracingOrigins = const [],
    this.sampleRate = 1.0,
    this.enabled = true,
    this.debug = false,
    this.captureErrors = true,
    this.reportSilentFlutterErrors = false,
    this.flushOnPause = true,
    this.sessionTimeout = const Duration(minutes: 30),
    this.screenIdleTimeout = const Duration(seconds: 1),
    this.screenMaxDuration = const Duration(seconds: 30),
    this.flushInterval = const Duration(seconds: 5),
    this.maxBatchSize = 100,
    this.maxQueueSize = 1000,
    this.httpClient,
    this.captureBodies,
    this.captureOutput = true,
    this.logs,
    this.logCorrelation,
  });

  /// The app's key from the Zharp dashboard, `zpk_…`. It can only send, so it is safe to ship in
  /// an app.
  final String key;

  /// `service.name`, e.g. `shop-app`.
  final String? service;

  /// `deployment.environment.name`, e.g. `production`.
  final String? environment;

  /// `service.version`, e.g. `shop-app@2.3.0+41`. Errors and traces are filtered by it.
  final String? release;

  /// Leave unset: the SDK sends straight to Zharp. (Used for Zharp's own testing.)
  final String? endpoint;

  /// False is logs-only mode: logs, errors (uncaught and `captureError`), the user, session,
  /// screen and tags are still sent, but no spans are created or exported — no screen-view
  /// spans, no HTTP client spans (`ZharpHttpClient`, `zharp_dio`), and no `traceparent` or
  /// `baggage` added to outgoing requests. `startSpan` still runs its callback. Defaults to true.
  final bool tracing;

  /// Hosts whose requests carry `traceparent` and `baggage`, so your back end continues the
  /// app's traces: `'api.example.com'`, `'*.example.com'`, `'https://api.example.com:8443'`, or
  /// a [RegExp] matched against the whole URL. Empty by default: trace headers are never sent to
  /// third parties unless listed, because some servers reject unknown headers.
  final List<Pattern> tracingOrigins;

  /// The share of traces kept, 0.0–1.0. Errors and logs are always sent.
  final double sampleRate;

  /// False starts nothing: a convenient switch for debug builds.
  final bool enabled;

  /// Print what the SDK does (`[Zharp] …`). Off by default: the SDK is silent apart from one
  /// warning when the key is rejected.
  final bool debug;

  /// Report uncaught errors (Flutter: `FlutterError.onError`, `PlatformDispatcher.onError`).
  final bool captureErrors;

  /// Also report the errors Flutter marks silent (e.g. an image that failed to load).
  final bool reportSilentFlutterErrors;

  /// Send what's queued when the app goes to the background (Flutter).
  final bool flushOnPause;

  /// A new session starts after this long in the background or idle.
  final Duration sessionTimeout;

  /// A screen-view span ends once nothing it started (requests, the first frame) has been running
  /// for this long…
  final Duration screenIdleTimeout;

  /// …or after this long at most.
  final Duration screenMaxDuration;

  final Duration flushInterval;

  /// Records per request.
  final int maxBatchSize;

  /// Spans (and, separately, logs) kept in memory while they can't be sent. When full, the
  /// oldest are dropped.
  final int maxQueueSize;

  /// Request and response bodies on HTTP CLIENT spans (`ZharpHttpClient`, `zharp_dio`). Off
  /// (null) by default. `CaptureBodies()` keeps them for failed requests only — status 400 and
  /// above, or no response; `CaptureBodies.all()` for every request. Every request the app makes
  /// is covered, never Zharp's own; `urls` narrows that.
  ///
  /// Text is kept up to 32 KB (`maxSize`, at most 128 KB). Field names always stay; values under
  /// secret-looking keys (`password`, `token`, `authorization`, `card`, …) become `[Filtered]`
  /// before anything leaves the app. Files in uploads, inline images and binary bodies are
  /// described — `[file photo.png · image/png · 240 KB]` — never sent. Other personal data in a
  /// body is sent as it is: add its keys to `redactKeys`.
  final CaptureBodies? captureBodies;

  /// Send what the app logs and prints. **Off by default**: nothing the app logs or prints is
  /// sent — on a server, the Zharp agent reads the app's output and brings those lines in,
  /// linked to their request by [logCorrelation]. Errors, traces, sessions and `Zharp.log` calls
  /// are sent either way. `true` — or `ZHARP_LOGS=true` in the environment or as a
  /// `--dart-define` — turns it on, e.g. in an app, or a server without the agent.
  final bool? logs;

  /// Dart servers and command-line tools (not Flutter, not the web): every line printed inside
  /// `ZharpCore.run` while a span is active ends with ` trace_id=<32 hex> span_id=<16 hex>` — or,
  /// for a JSON line, gets `"trace_id"` and `"span_id"` fields — so a line the Zharp agent collects
  /// is linked to its request. Lines outside a span and lines that already carry a `trace_id`
  /// are left alone. On by default; `false` (or `ZHARP_LOG_CORRELATION=false`) turns it off.
  final bool? logCorrelation;

  /// With [logs] on: send what the app prints as logs, each line tied to the trace and session
  /// it was written in. On by default; `false` — or `ZHARP_CAPTURE_OUTPUT=false` in the
  /// environment or as a `--dart-define` — leaves only `Zharp.log` calls.
  ///
  /// - `package:logging` records, with their own level and logger name (`log.logger`).
  /// - Flutter's `debugPrint` (zharp_flutter), which Flutter and many packages log through.
  /// - Inside `Zharp.guard` (Flutter) or `ZharpCore.run` (Dart): `print` — and so the `logger`
  ///   package, whose boxes become one record — and writes to `stdout`/`stderr`.
  ///
  /// A line's level is read from the line (a JSON `level`, `ERROR`, `[warn]`, `level=error`,
  /// `SEVERE`, the `logger` package's `[E]` or emoji), else info — warning on `stderr`. What is
  /// printed is unchanged, and a line is never sent twice.
  final bool captureOutput;

  /// The client telemetry is sent with; one is made when not given. Not the client your app's
  /// requests are traced on — see `ZharpHttpClient`.
  final http.Client? httpClient;
}
