import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zharp_logs_flutter/zharp_logs_flutter.dart';

void main() {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', 202);
  });
  List<Map<String, dynamic>> logs() => [
        for (final r in requests) ...(jsonDecode(r.body)['logs'] as List).cast<Map<String, dynamic>>(),
      ];

  setUp(requests.clear);

  void start({bool capturePrint = false}) => ZharpFlutter.init(
        apiKey: 'key-123',
        service: 'shop-app',
        httpClient: client,
        flushInterval: const Duration(minutes: 1),
        capturePrint: capturePrint,
      );

  testWidgets('sends logs as flutter-logs with Flutter context', (tester) async {
    start();
    ZharpLogger.info('Checkout opened');
    await tester.runAsync(ZharpLogger.flushAll);

    expect(requests.single.headers['x-zharp-sdk'], 'flutter-logs/${ZharpFlutter.version}');
    final context = (logs().single['metadata'] as Map)['context'] as Map;
    expect(context['framework'], 'flutter');
    expect(context['buildMode'], 'debug');
    expect(context['platform'], isNotNull);
    await tester.runAsync(ZharpFlutter.close);
  });

  testWidgets('a Flutter framework error is sent, and the previous handler still runs', (tester) async {
    start();
    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('layout exploded'),
      stack: StackTrace.current,
      library: 'widgets library',
      context: ErrorDescription('while building ShopPage'),
    ));
    // The test binding's own handler recorded it; taking it shows the previous handler ran.
    expect(tester.takeException(), isA<StateError>());
    await tester.runAsync(ZharpLogger.flushAll);

    final entry = logs().single;
    expect(entry['level'], 'error');
    expect(entry['message'], 'Bad state: layout exploded');
    final metadata = entry['metadata'] as Map;
    expect(metadata['type'], 'flutterError');
    expect(metadata['name'], 'StateError');
    expect(metadata['library'], 'widgets library');
    expect(metadata['errorContext'], 'while building ShopPage');
    expect(metadata['stack'], isNotEmpty);
    await tester.runAsync(ZharpFlutter.close);
  });

  testWidgets('an uncaught async error is sent; the previous handler decides if it is handled', (tester) async {
    var previousCalled = false;
    PlatformDispatcher.instance.onError = (error, stack) {
      previousCalled = true;
      return true;
    };
    start();
    final handled = PlatformDispatcher.instance.onError!(const FormatException('bad json'), StackTrace.current);
    expect(handled, isTrue);
    expect(previousCalled, isTrue);
    await tester.runAsync(ZharpLogger.flushAll);

    final entry = logs().single;
    expect(entry['message'], 'FormatException: bad json');
    expect((entry['metadata'] as Map)['type'], 'uncaughtError');
    await tester.runAsync(ZharpFlutter.close);
    PlatformDispatcher.instance.onError = null;
  });

  testWidgets('going to the background sends what is queued', (tester) async {
    start();
    ZharpLogger.info('added to cart');
    expect(requests, isEmpty, reason: 'info waits for the timer (a minute here)');
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(logs().single['message'], 'added to cart');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(ZharpFlutter.close);
  });

  testWidgets('capturePrint sends debugPrint output, but not the SDK own lines', (tester) async {
    start(capturePrint: true);
    debugPrint('cart has 3 items');
    debugPrint('[Zharp] internal');
    await tester.runAsync(ZharpLogger.flushAll);
    expect(logs().map((e) => e['message']), ['cart has 3 items']);
    await tester.runAsync(ZharpFlutter.close);
  });

  testWidgets('close puts the original handlers back', (tester) async {
    final originalFlutter = FlutterError.onError;
    final originalPrint = debugPrint;
    start(capturePrint: true);
    expect(FlutterError.onError, isNot(same(originalFlutter)));
    await tester.runAsync(ZharpFlutter.close);
    expect(FlutterError.onError, same(originalFlutter));
    expect(debugPrint, same(originalPrint));
    expect(ZharpLogger.isActive, isFalse);
  });

  testWidgets('without an API key nothing starts and no handlers are touched', (tester) async {
    final originalFlutter = FlutterError.onError;
    ZharpFlutter.init(service: 'x', httpClient: client);
    expect(ZharpLogger.isActive, isFalse);
    expect(FlutterError.onError, same(originalFlutter));
  });
}
