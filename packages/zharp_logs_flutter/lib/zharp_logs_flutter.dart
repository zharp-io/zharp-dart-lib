/// Send your Flutter app's logs and crashes to Zharp.
///
/// ```dart
/// void main() {
///   ZharpFlutter.init(apiKey: 'your-ingest-only-key', service: 'shop-app');
///   runApp(const MyApp());
/// }
/// ```
///
/// Then log anywhere with [ZharpLogger], e.g. `ZharpLogger.info('Checkout opened')`.
library;

import 'dart:async';
import 'dart:ui' show AppLifecycleState, ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
// The two hooks an integration needs; not part of zharp_logs' public API.
// ignore: implementation_imports
import 'package:zharp_logs/src/logger.dart' show setIntegrationContext;
// ignore: implementation_imports
import 'package:zharp_logs/src/version.dart' as core;
import 'package:zharp_logs/zharp_logs.dart';

export 'package:zharp_logs/zharp_logs.dart';

/// Starts [ZharpLogger] for a Flutter app, with Flutter's error and lifecycle hooks.
abstract final class ZharpFlutter {
  /// This package's version.
  static const String version = '0.1.1';

  static FlutterExceptionHandler? _previousFlutterError;
  static ErrorCallback? _previousPlatformError;
  static DebugPrintCallback? _previousDebugPrint;
  static _Lifecycle? _lifecycle;
  static bool _capturingErrors = false;

  /// Start sending logs. Call it first thing in `main()`, before `runApp`.
  ///
  /// Takes the same options as [ZharpLogger.init] — anything left out is read from
  /// `--dart-define` (`ZHARP_API_KEY`, `ZHARP_SERVICE`, `ZHARP_ENV`, …). On top of that:
  ///
  /// - [captureErrors] (on): Flutter framework errors (`FlutterError.onError`) and uncaught async
  ///   errors (`PlatformDispatcher.onError`) are sent as `error` logs with their stack. Handlers
  ///   already set are kept and still called.
  /// - [flushOnBackground] (on): what's queued is sent when the app goes to the background, the
  ///   last moment it's reliably running.
  /// - [capturePrint] (off): also send what the app writes with `debugPrint`, as `info` logs.
  static void init({
    String? apiKey,
    String? service,
    String? environment,
    String? appVersion,
    String? source,
    String? endpoint,
    Duration flushInterval = const Duration(seconds: 5),
    int maxBatchSize = 50,
    bool captureErrors = true,
    bool flushOnBackground = true,
    bool? capturePrint,
    http.Client? httpClient,
  }) {
    WidgetsFlutterBinding.ensureInitialized();
    _unhook();
    core.sdkName = 'flutter-logs/$version';

    ZharpLogger.init(
      apiKey: apiKey,
      service: service,
      environment: environment,
      appVersion: appVersion,
      source: source,
      endpoint: endpoint,
      flushInterval: flushInterval,
      maxBatchSize: maxBatchSize,
      capturePrint: capturePrint,
      httpClient: httpClient,
    );
    if (!ZharpLogger.isActive) return;

    setIntegrationContext({
      'framework': 'flutter',
      'buildMode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    });

    if (captureErrors) _hookErrors();
    if (flushOnBackground) {
      _lifecycle = _Lifecycle();
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
    if (capturePrint ?? false) _hookDebugPrint();
  }

  /// Send everything queued, stop logging, and put back the handlers [init] replaced.
  static Future<void> close() async {
    _unhook();
    await ZharpLogger.close();
  }

  static void _hookErrors() {
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _sendFlutterError(details);
      // Flutter's own handler prints the error (and in debug, shows the red screen); keep it.
      (_previousFlutterError ?? FlutterError.presentError)(details);
    };

    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      ZharpLogger.captureException(error, stack, metadata: {'type': 'uncaughtError'});
      // What a handler set before decides whether the error counts as handled; with none, it
      // doesn't, so Flutter reports it as it would have.
      return _previousPlatformError?.call(error, stack) ?? false;
    };
    _capturingErrors = true;
  }

  static void _sendFlutterError(FlutterErrorDetails details) {
    final metadata = <String, Object?>{
      'type': 'flutterError',
      'name': details.exception.runtimeType.toString(),
      if (details.stack != null) 'stack': details.stack.toString(),
      if (details.library != null) 'library': details.library,
      if (details.context != null) 'errorContext': details.context.toString(),
    };
    // Errors Flutter itself marks silent (an image that failed to load, say) are worth seeing
    // but not worth an alert.
    if (details.silent) {
      ZharpLogger.warn(details.exceptionAsString(), {...metadata, 'silent': true});
    } else {
      ZharpLogger.log(LogLevel.error, details.exceptionAsString(), metadata: metadata);
    }
  }

  static void _hookDebugPrint() {
    _previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _previousDebugPrint!(message, wrapWidth: wrapWidth);
      if (message == null || message.trim().isEmpty || message.startsWith('[Zharp]')) return;
      ZharpLogger.info(message, {'origin': 'debugPrint'});
    };
  }

  static void _unhook() {
    if (_capturingErrors) {
      FlutterError.onError = _previousFlutterError;
      PlatformDispatcher.instance.onError = _previousPlatformError;
      _previousFlutterError = null;
      _previousPlatformError = null;
      _capturingErrors = false;
    }
    if (_previousDebugPrint != null) {
      debugPrint = _previousDebugPrint!;
      _previousDebugPrint = null;
    }
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
      _lifecycle = null;
    }
    setIntegrationContext({});
  }
}

/// Sends what's queued when the app leaves the foreground: a backgrounded mobile app can be
/// killed at any moment without being told.
class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      unawaited(ZharpLogger.flushAll());
    }
  }
}
