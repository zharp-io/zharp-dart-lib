// Run by dart_program_test.dart with ZHARP_* set: prints what ZharpCore took from them.
import 'dart:convert';

import 'package:zharp_core/zharp_core.dart';

Future<void> main() async {
  final zharp = ZharpCore.start(const ZharpOptions())!;
  print(jsonEncode({
    'service.name': zharp.resource['service.name'],
    'deployment.environment.name': zharp.resource['deployment.environment.name'],
    'service.version': zharp.resource['service.version'],
    'endpoint': zharp.endpoint,
  }));
  await zharp.close(timeout: const Duration(milliseconds: 100));
}
