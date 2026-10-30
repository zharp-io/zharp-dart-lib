// Sends a trace with an exception, a CLIENT span, a log and a handled error to a running Zharp,
// then prints the IDs to look for. The key comes from the environment — never commit one.
//
//   ZHARP_KEY=zpk_… ZHARP_ENDPOINT=http://localhost:3000/api/v1/otlp dart run tool/e2e.dart
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zharp_core/zharp_core.dart';

Future<void> main() async {
  final key = Platform.environment['ZHARP_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set ZHARP_KEY');
    exit(2);
  }
  final run = DateTime.now().millisecondsSinceEpoch.toString();
  final zharp = ZharpCore.start(
      ZharpOptions(
        key: key,
        service: 'flutter-e2e',
        environment: 'e2e',
        release: 'flutter-e2e@$sdkVersion',
        endpoint: Platform.environment['ZHARP_ENDPOINT'],
        tracingOrigins: ['api.example.test'],
        debug: true,
      ),
      resourceAttributes: {
        'device.id': 'e2e-install-$run',
        'device.model.name': 'Pixel 9 (e2e)',
        'os.name': 'Android',
        'os.version': '15',
      })!;
  zharp.setUser(id: 'e2e-user-$run', email: 'e2e@zharp.test');

  // A back end the app calls, faked, so the CLIENT span and propagated headers are real.
  String? sentTraceparent;
  final api = ZharpHttpClient(MockClient((request) async {
    sentTraceparent = request.headers['traceparent'];
    return http.Response('[]', 200);
  }));

  final screen = zharp.tracer.startIdle('screen /checkout',
      idleTimeout: const Duration(milliseconds: 200),
      maxDuration: const Duration(seconds: 5),
      attributes: {'app.screen.name': '/checkout'});
  try {
    await zharp.tracer.runWith(
        screen.span,
        () => zharp.startSpan('place order $run', (span) async {
              await api.get(Uri.parse('https://api.example.test/orders'));
              zharp.log.info('Placing order $run', {'items': 3});
              throw StateError('payment declined $run');
            }));
  } catch (_) {
    // Recorded on the span as unhandled.
  }
  try {
    throw const FormatException('handled e2e error');
  } catch (e, st) {
    zharp.captureError(e, stackTrace: st, attributes: {'run': run});
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));

  print('run=$run');
  print('trace_id=${screen.span.traceId}');
  print('session_id=${zharp.session.id}');
  print('traceparent sent to api.example.test: $sentTraceparent');
  await zharp.close();
  print('pending after close: ${zharp.pending}');
}
