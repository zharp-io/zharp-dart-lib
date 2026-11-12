/// Zharp Application Monitoring for Flutter: errors, logs, screen views, traced HTTP requests
/// and sessions, sent as OpenTelemetry (OTLP).
///
/// ```dart
/// Future<void> main() async {
///   await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', environment: 'production'));
///   runApp(const MyApp());
/// }
/// ```
library;

export 'package:zharp_core/zharp_core.dart'
    show BodyMode, CaptureBodies, Severity, SpanKind, ZharpHttpClient, ZharpOptions, ZharpSpan, ZharpUser, sdkVersion;

export 'src/navigator_observer.dart' show ZharpNavigatorObserver;
export 'src/zharp.dart' show Zharp, ZharpLogger;
