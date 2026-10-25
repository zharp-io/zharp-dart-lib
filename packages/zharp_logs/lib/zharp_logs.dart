/// Send your Dart and Flutter app's logs to Zharp.
///
/// ```dart
/// import 'package:zharp_logs/zharp_logs.dart';
///
/// void main() {
///   ZharpLogger.init(apiKey: 'your-ingest-only-key', service: 'checkout-api');
///   ZharpLogger.info('User signed in', {'userId': 42});
/// }
/// ```
library;

export 'src/logger.dart' show LogLevel, ZharpLogger;
export 'src/version.dart' show version;
