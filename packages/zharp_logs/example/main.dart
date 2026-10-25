import 'package:zharp_logs/zharp_logs.dart';

/// Run with: ZHARP_API_KEY=your-ingest-only-key dart run example/main.dart
Future<void> main() async {
  ZharpLogger.init(service: 'example-cli', environment: 'development');

  await ZharpLogger.guard(() async {
    ZharpLogger.info('Import started', {'file': 'orders.csv'});
    try {
      throw const FormatException('Row 12: missing price');
    } catch (e, stack) {
      ZharpLogger.captureException(e, stack, metadata: {'row': 12});
    }
    ZharpLogger.info('Import finished', {'rows': 120});
  });

  // A script that's done sends what's left and exits straight away.
  await ZharpLogger.close();
}
