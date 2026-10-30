import 'package:http/http.dart' as http;

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

  /// The OTLP endpoint. Defaults to [defaultEndpoint]; `/v1/traces` and `/v1/logs` are appended.
  final String? endpoint;

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

  /// The client telemetry is sent with; one is made when not given. Not the client your app's
  /// requests are traced on — see `ZharpHttpClient`.
  final http.Client? httpClient;
}
