import 'dart:async';
import 'dart:ui' show AppLifecycleState, ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:zharp_core/zharp_core.dart';

import 'device.dart';

/// Zharp Application Monitoring for Flutter.
///
/// ```dart
/// Future<void> main() async {
///   await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', environment: 'production'));
///   runApp(const MyApp());
/// }
/// ```
///
/// Then, once someone signs in: `Zharp.setUser(id: user.id, email: user.email)`.
///
/// Every method is safe to call before [init], after [close], or when Zharp is disabled — it
/// does nothing then — and none of them throws into your app.
abstract final class Zharp {
  static FlutterExceptionHandler? _previousFlutterError;
  static ErrorCallback? _previousPlatformError;
  static bool _hookedErrors = false;
  static _Lifecycle? _lifecycle;
  static DebugPrintCallback? _previousDebugPrint;

  /// Start Zharp. Call it first thing in `main()`, before `runApp`.
  ///
  /// From then on, uncaught errors (`FlutterError.onError`, `PlatformDispatcher.onError`) are
  /// reported — handlers already set are kept and still called — and what's queued is sent when
  /// the app goes to the background. Add [ZharpNavigatorObserver] to your app for screen views,
  /// and use [ZharpHttpClient] (or `zharp_dio`) for traced requests.
  ///
  /// Calling it again replaces the running setup.
  static Future<void> init(ZharpOptions options) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _unhook();
      // No agent reads a phone's output: lines are never stamped.
      final core = ZharpCore.start(options, stampLines: false);
      if (core == null) return;
      // Device details come from native code. Startup waits for them only briefly — a cold
      // emulator can take seconds to answer — and they join the resource whenever they arrive.
      final device = collectDeviceContext(options.service ?? 'app').then((device) {
        core.updateResource(device.resource, defaultRelease: device.release);
        if (options.debug) debugPrint('[Zharp] Device context: ${device.resource}');
      });
      await device.timeout(const Duration(milliseconds: 500), onTimeout: () {});
      if (options.captureErrors) _hookErrors(options);
      if (core.capturesOutput) _hookDebugPrint();
      _lifecycle = _Lifecycle();
      WidgetsBinding.instance.addObserver(_lifecycle!);
    } catch (error) {
      if (options.debug) debugPrint('[Zharp] Could not start: $error');
    }
  }

  /// Whether Zharp is running.
  static bool get isEnabled => ZharpCore.instance != null;

  /// The running SDK, for integrations. Null before [init].
  static ZharpCore? get core => ZharpCore.instance;

  /// Identify the signed-in user: `id` (any value; sent as text) becomes `enduser.id`, [email] and
  /// [name] `enduser.email` and `enduser.name`.
  static void setUser({required Object id, String? email, String? name}) =>
      ZharpCore.instance?.setUser(id: '$id', email: email, name: name);

  /// Forget the user, e.g. on sign-out. Also starts a new session.
  static void clearUser() => ZharpCore.instance?.clearUser();

  /// Add [key] = [value] to every span, log and error from now on. `null` removes it.
  static void setTag(String key, Object? value) => ZharpCore.instance?.setTag(key, value);

  /// Report an error you caught. It is grouped into an issue with others like it.
  ///
  /// ```dart
  /// try { await pay(); } catch (error, stack) { Zharp.captureError(error, stackTrace: stack); }
  /// ```
  static void captureError(Object error, {StackTrace? stackTrace, Map<String, Object?>? attributes}) =>
      ZharpCore.instance?.captureError(error, stackTrace: stackTrace, attributes: attributes);

  /// Logs: `Zharp.log.info('Checkout opened', {'items': 3})`. Also `debug`, `warn`, `error`.
  static const ZharpLogger log = ZharpLogger._();

  /// Run [body] in a span named [name], ended when [body] (or its Future) completes. Requests
  /// and spans started inside become its children; an error thrown out of it is recorded.
  ///
  /// ```dart
  /// await Zharp.startSpan('checkout', (span) async {
  ///   span.setAttribute('cart.items', cart.length);
  ///   await api.placeOrder(cart);
  /// });
  /// ```
  static T startSpan<T>(String name, T Function(ZharpSpan span) body, {Map<String, Object?>? attributes}) {
    final core = ZharpCore.instance;
    if (core == null) return body(_inactiveSpan);
    return core.startSpan(name, body, attributes: attributes);
  }

  /// The span work started now belongs to: one from [startSpan], else the current screen view.
  static ZharpSpan? get currentSpan => ZharpCore.instance?.tracer.current;

  /// The current session ID.
  static String? get sessionId => ZharpCore.instance?.session.id;

  /// Send everything queued now.
  static Future<void> flush() async => ZharpCore.instance?.flush();

  /// Send everything queued, stop, and put back the error handlers [init] replaced.
  static Future<void> close() async {
    _unhook();
    await ZharpCore.instance?.close();
  }

  /// Run [body] in a zone whose uncaught errors are reported, and where `print` — and so the
  /// `logger` package and anything else printing — is sent as logs too (with
  /// [ZharpOptions.captureOutput], the default). Without it, [init] still catches what reaches
  /// Flutter's error handlers, `debugPrint` and `package:logging`, but not `print`: Dart offers
  /// no way to see it outside a zone. Call [init] *inside* it, so Flutter's binding and `runApp`
  /// share the zone:
  ///
  /// ```dart
  /// void main() => Zharp.guard(() async {
  ///   await Zharp.init(ZharpOptions(key: 'zpk_…'));
  ///   runApp(const MyApp());
  /// });
  /// ```
  static void guard(FutureOr<void> Function() body) {
    runZonedGuarded(() => runCapturingOutput(body), (error, stack) {
      reportUncaught(error, stack, mechanism: 'zone');
      // Still printed, as an uncaught error would be.
      FlutterError.presentError(FlutterErrorDetails(exception: error, stack: stack, library: 'zharp guard'));
    });
  }

  /// Report an uncaught error (handled = false) and send it right away: the app may not live long.
  @visibleForTesting
  static void reportUncaught(Object error, StackTrace? stack,
      {required String mechanism, Map<String, Object?>? attributes}) {
    final core = ZharpCore.instance;
    if (core == null) return;
    core.captureError(error,
        stackTrace: stack, handled: false, attributes: {'zharp.mechanism': mechanism, ...?attributes});
    unawaited(core.flush());
  }

  static void _hookErrors(ZharpOptions options) {
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.silent || options.reportSilentFlutterErrors) {
        reportUncaught(details.exception, details.stack, mechanism: 'FlutterError', attributes: {
          if (details.library != null) 'flutter.library': details.library,
          if (details.context != null) 'flutter.context': _safeText(details.context),
          if (details.silent) 'flutter.silent': true,
        });
      }
      // Flutter's own handling — the console dump, the red screen in debug — stays.
      (_previousFlutterError ?? FlutterError.presentError)(details);
    };

    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      reportUncaught(error, stack, mechanism: 'PlatformDispatcher');
      // A handler set before decides whether it counts as handled; with none, it doesn't, and
      // Flutter reports it as it would have.
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    _hookedErrors = true;
  }

  /// `debugPrint` — where Flutter's own messages and many packages log — is sent as logs too, and
  /// still printed. Its throttled printing happens later, so each line is remembered once sent.
  static void _hookDebugPrint() {
    if (identical(debugPrint, _debugPrint)) return;
    _previousDebugPrint = debugPrint;
    debugPrint = _debugPrint;
  }

  static void _debugPrint(String? message, {int? wrapWidth}) {
    captureMessage(message, source: 'debugPrint', remember: true);
    final original = _previousDebugPrint ?? debugPrintThrottled;
    // What it prints right away is already captured.
    quietly(() => original(message, wrapWidth: wrapWidth));
  }

  static String? _safeText(Object? value) {
    try {
      return value?.toString();
    } catch (_) {
      return null;
    }
  }

  static void _unhook() {
    if (_previousDebugPrint != null) {
      if (identical(debugPrint, _debugPrint)) debugPrint = _previousDebugPrint!;
      _previousDebugPrint = null;
    }
    if (_hookedErrors) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
      _previousFlutterError = null;
      _previousPlatformError = null;
      _hookedErrors = false;
    }
    final lifecycle = _lifecycle;
    if (lifecycle != null) {
      WidgetsBinding.instance.removeObserver(lifecycle);
      _lifecycle = null;
    }
  }

  static final ZharpSpan _inactiveSpan = ZharpSpan.internal(
    traceId: '0' * 32,
    spanId: '0' * 16,
    parentSpanId: null,
    name: '',
    kind: SpanKind.internal,
    sampled: false,
    startMicros: 0,
    attributes: {},
    onEnd: (_) {},
    clock: DateTime.now,
  );
}

/// `Zharp.log`: OTLP log records tied to the current trace, with the session, user and tags.
/// Dropped before `Zharp.init`.
final class ZharpLogger {
  const ZharpLogger._();

  void debug(Object? message, [Map<String, Object?>? attributes]) => ZharpCore.instance?.log.debug(message, attributes);
  void info(Object? message, [Map<String, Object?>? attributes]) => ZharpCore.instance?.log.info(message, attributes);
  void warn(Object? message, [Map<String, Object?>? attributes]) => ZharpCore.instance?.log.warn(message, attributes);

  /// An error log. Pass an exception (`Zharp.log.error(e)`) and it is reported as an error too.
  void error(Object? message, [Map<String, Object?>? attributes]) => ZharpCore.instance?.log.error(message, attributes);
  void fatal(Object? message, [Map<String, Object?>? attributes]) => ZharpCore.instance?.log.fatal(message, attributes);
}

/// Background and foreground: flush on the way out (a backgrounded app can be killed without
/// notice), and a new session after a long absence.
class _Lifecycle with WidgetsBindingObserver {
  bool _away = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final core = ZharpCore.instance;
    if (core == null) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_away) return;
        _away = true;
        unawaited(core.onBackground());
      case AppLifecycleState.resumed:
        if (!_away) return;
        _away = false;
        core.onForeground();
      case AppLifecycleState.inactive:
        break;
    }
  }
}
