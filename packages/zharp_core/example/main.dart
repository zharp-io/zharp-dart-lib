// zharp_core on its own, in any Dart program. Flutter apps use zharp_flutter instead.
import 'package:zharp_core/zharp_core.dart';

Future<void> main() async {
  final zharp = ZharpCore.start(const ZharpOptions(
    key: String.fromEnvironment('ZHARP_KEY'),
    service: 'example-tool',
    environment: 'development',
  ));
  if (zharp == null) return;

  zharp.setUser(id: 'user-42');
  await zharp.startSpan('import orders', (span) async {
    final client = ZharpHttpClient();
    try {
      await client.get(Uri.parse('https://example.com/'));
    } finally {
      client.close();
    }
    zharp.log.info('Imported', {'count': 3});
  });

  try {
    throw StateError('Something went wrong');
  } catch (error, stack) {
    zharp.captureError(error, stackTrace: stack);
  }
  await zharp.close();
}
