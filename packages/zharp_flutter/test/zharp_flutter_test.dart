import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zharp_flutter/src/device.dart';
import 'package:zharp_flutter/zharp_flutter.dart';

/// A fake Zharp ingest.
class Backend {
  final List<http.Request> requests = [];
  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', 200);
  });

  Map<String, dynamic> _body(http.Request r) =>
      jsonDecode(utf8.decode(r.headers['Content-Encoding'] == 'gzip' ? gzip.decode(r.bodyBytes) : r.bodyBytes))
          as Map<String, dynamic>;

  List<Map<String, dynamic>> records(String path, String outer, String scope, String inner) => [
        for (final r in requests.where((r) => r.url.path.endsWith('/v1/$path')))
          for (final x in _body(r)[outer] as List)
            for (final s in x[scope] as List) ...(s[inner] as List).cast<Map<String, dynamic>>(),
      ];

  List<Map<String, dynamic>> get spans => records('traces', 'resourceSpans', 'scopeSpans', 'spans');
  List<Map<String, dynamic>> get logs => records('logs', 'resourceLogs', 'scopeLogs', 'logRecords');

  Map<String, Object?> get resource {
    final b = _body(requests.first);
    return attrs(((b['resourceSpans'] ?? b['resourceLogs']) as List).first['resource']['attributes'] as List);
  }
}

Map<String, Object?> attrs(List<dynamic> list) => {
      for (final kv in list)
        kv['key'] as String: (kv['value'] as Map).values.first is String && (kv['value'] as Map).containsKey('intValue')
            ? int.parse((kv['value'] as Map).values.first as String)
            : (kv['value'] as Map).values.first,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Backend backend;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockDevice() => messenger.setMockMethodCallHandler(deviceChannel, (call) async {
        if (call.method != 'deviceInfo') return null;
        return {
          'model': 'Pixel 8',
          'manufacturer': 'Google',
          'osName': 'Android',
          'osVersion': '15',
          'installId': 'install-123',
          'appId': 'com.shop.app',
          'appVersion': '2.3.0',
          'appBuild': '41',
        };
      });

  ZharpOptions options(
          {String? release,
          bool captureErrors = true,
          bool tracing = true,
          List<Pattern> tracingOrigins = const []}) =>
      ZharpOptions(
        key: 'zpk_test',
        service: 'shop-app',
        environment: 'production',
        release: release,
        endpoint: 'https://ingest.test/api/v1/otlp',
        tracing: tracing,
        tracingOrigins: tracingOrigins,
        captureErrors: captureErrors,
        httpClient: backend.client,
      );

  setUp(() {
    backend = Backend();
    mockDevice();
  });
  tearDown(() async {
    await Zharp.close();
    messenger.setMockMethodCallHandler(deviceChannel, null);
  });

  group('init', () {
    test('device context from the plugin; the app version is the default release', () async {
      await Zharp.init(options());
      expect(Zharp.isEnabled, isTrue);
      Zharp.log.info('hi');
      await Zharp.flush();
      final r = backend.resource;
      expect(r['device.model.name'], 'Google Pixel 8');
      expect(r['device.model.identifier'], 'Pixel 8');
      expect(r['device.manufacturer'], 'Google');
      expect(r['device.id'], 'install-123');
      expect(r['os.name'], 'Android');
      expect(r['os.version'], '15');
      expect(r['service.version'], 'com.shop.app@2.3.0+41');
      expect(r['telemetry.sdk.language'], 'dart');
      expect(r['service.name'], 'shop-app');
    });

    test('a release passed in wins', () async {
      await Zharp.init(options(release: 'shop@9'));
      Zharp.log.info('hi');
      await Zharp.flush();
      expect(backend.resource['service.version'], 'shop@9');
    });

    test('without the plugin: an install ID that persists, OS from Dart', () async {
      messenger.setMockMethodCallHandler(deviceChannel, null);
      final first = await collectDeviceContext('zharp-flutter-test');
      final second = await collectDeviceContext('zharp-flutter-test');
      expect(first.resource['device.id'], isNotEmpty);
      expect(second.resource['device.id'], first.resource['device.id']);
      expect(first.release, isNull);
    });

    test('model names: manufacturer once', () {
      expect(modelName('Google', 'Pixel 8'), 'Google Pixel 8');
      expect(modelName('samsung', 'SM-S911B'), 'samsung SM-S911B');
      expect(modelName('OnePlus', 'OnePlus 12'), 'OnePlus 12');
      expect(modelName('Apple', 'iPhone15,2'), 'iPhone15,2');
    });

    test('before init and after close nothing happens and nothing throws', () async {
      await Zharp.close();
      Zharp.setUser(id: 1);
      Zharp.log.error('x');
      Zharp.captureError(StateError('x'));
      expect(Zharp.startSpan('x', (_) => 5), 5);
      await Zharp.flush();
      expect(backend.requests, isEmpty);
    });
  });

  group('errors', () {
    test('FlutterError.onError: reported unhandled, sent at once, and the old handler still runs', () async {
      final seen = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      void handler(FlutterErrorDetails details) => seen.add(details);
      FlutterError.onError = handler;
      try {
        await Zharp.init(options());
        Zharp.setUser(id: 42, email: 'a@b.test');
        FlutterError.reportError(FlutterErrorDetails(
          exception: StateError('layout broke'),
          stack: StackTrace.current,
          library: 'widgets library',
        ));
        await Future<void>.delayed(Duration.zero);
        await Zharp.flush();
        expect(seen, hasLength(1));
        final log = backend.logs.single;
        expect(log['severityNumber'], 17);
        final a = attrs(log['attributes'] as List);
        expect(a['exception.type'], 'StateError');
        expect(a['zharp.handled'], 'false');
        expect(a['zharp.mechanism'], 'FlutterError');
        expect(a['flutter.library'], 'widgets library');
        expect(a['enduser.id'], '42');
        expect(a['session.id'], Zharp.sessionId);
        expect((a['exception.stacktrace'] as String).split('\n')[1], startsWith('#0'));
      } finally {
        await Zharp.close();
        expect(FlutterError.onError, same(handler));
        FlutterError.onError = original;
      }
    });

    test('silent Flutter errors are skipped by default', () async {
      final original = FlutterError.onError;
      FlutterError.onError = (_) {};
      try {
        await Zharp.init(options());
        FlutterError.reportError(FlutterErrorDetails(exception: Exception('image'), silent: true));
        await Zharp.flush();
        expect(backend.logs, isEmpty);
      } finally {
        await Zharp.close();
        FlutterError.onError = original;
      }
    });

    test('PlatformDispatcher.onError: reported unhandled; the previous handler decides', () async {
      final dispatcher = PlatformDispatcher.instance;
      final original = dispatcher.onError;
      dispatcher.onError = (_, __) => true;
      try {
        await Zharp.init(options());
        final handled = dispatcher.onError!(const FormatException('bad'), StackTrace.current);
        expect(handled, isTrue);
        await Zharp.flush();
        final a = attrs(backend.logs.single['attributes'] as List);
        expect(a['exception.type'], 'FormatException');
        expect(a['zharp.mechanism'], 'PlatformDispatcher');
        expect(a['zharp.handled'], 'false');
      } finally {
        await Zharp.close();
        dispatcher.onError = original;
      }
    });

    test('captureError is handled', () async {
      await Zharp.init(options());
      Zharp.captureError(StateError('x'), stackTrace: StackTrace.current, attributes: {'order': 1});
      await Zharp.flush();
      expect(attrs(backend.logs.single['attributes'] as List)['zharp.handled'], 'true');
    });

    test('guard reports zone errors', () async {
      await Zharp.init(options());
      final original = FlutterError.presentError;
      final presented = <FlutterErrorDetails>[];
      FlutterError.presentError = presented.add;
      try {
        Zharp.guard(() async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('in zone');
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await Zharp.flush();
        expect(attrs(backend.logs.single['attributes'] as List)['zharp.mechanism'], 'zone');
        expect(presented, hasLength(1));
      } finally {
        FlutterError.presentError = original;
      }
    });
  });

  group('screens and requests', () {
    testWidgets('a screen view per page route, with its requests as children', (tester) async {
      final app = MockClient((request) async => http.Response('[]', 200));
      await Zharp.init(options(tracingOrigins: ['api.shop.test']));
      final api = ZharpHttpClient(app);
      final navigator = GlobalKey<NavigatorState>();

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [ZharpNavigatorObserver()],
        initialRoute: '/',
        routes: {
          '/': (_) => const Text('home'),
          '/cart': (_) => _LoadsOnOpen(api),
        },
      ));
      await tester.pump();
      navigator.currentState!.pushNamed('/cart');
      await tester.pumpAndSettle();
      // Idle timeout after the request.
      await tester.pump(const Duration(seconds: 2));
      Zharp.log.info('later');
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await Zharp.flush();

      final spans = backend.spans;
      final cart = spans.firstWhere((s) => s['name'] == 'screen /cart');
      final home = spans.where((s) => s['name'] == 'screen /').toList();
      expect(home, hasLength(2)); // initial, then back
      expect(cart.containsKey('parentSpanId'), isFalse);
      final cartAttrs = attrs(cart['attributes'] as List);
      expect(cartAttrs['app.screen.name'], '/cart');
      expect(cartAttrs['zharp.navigation.action'], 'push');
      expect(cartAttrs['zharp.navigation.from'], '/');
      expect(attrs(home.last['attributes'] as List)['zharp.navigation.action'], 'pop');

      final request = spans.firstWhere((s) => s['name'] == 'GET api.shop.test/cart');
      expect(request['parentSpanId'], cart['spanId']);
      expect(request['traceId'], cart['traceId']);
      expect(request['kind'], 3);

      final log = backend.logs.single;
      expect(attrs(log['attributes'] as List)['app.screen.name'], '/cart');
      await Zharp.close();
    });

    testWidgets('tracing: false — no screen or request spans, no trace headers; logs keep the screen',
        (tester) async {
      final seen = <http.BaseRequest>[];
      final app = MockClient((request) async {
        seen.add(request);
        return http.Response('[]', 200);
      });
      await Zharp.init(options(tracing: false, tracingOrigins: ['api.shop.test']));
      final api = ZharpHttpClient(app);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [ZharpNavigatorObserver()],
        initialRoute: '/',
        routes: {
          '/': (_) => const Text('home'),
          '/cart': (_) => _LoadsOnOpen(api),
        },
      ));
      await tester.pump();
      navigator.currentState!.pushNamed('/cart');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      Zharp.log.info('on cart');
      Zharp.captureError(StateError('oops'));
      expect(Zharp.startSpan('work', (_) => 5), 5);
      await Zharp.flush();

      expect(backend.spans, isEmpty);
      expect(seen, isNotEmpty);
      expect(seen.every((r) => !r.headers.containsKey('traceparent') && !r.headers.containsKey('baggage')), isTrue);
      expect(backend.logs, hasLength(2));
      expect(attrs(backend.logs.first['attributes'] as List)['app.screen.name'], '/cart');
      expect(attrs(backend.logs.last['attributes'] as List)['exception.type'], 'StateError');
      await Zharp.close();
    });

    testWidgets('dialogs and unnamed routes are not screens', (tester) async {
      await Zharp.init(options());
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [ZharpNavigatorObserver()],
        home: const Text('home'),
      ));
      navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('unnamed')));
      await tester.pumpAndSettle();
      showDialog<void>(context: navigator.currentContext!, builder: (_) => const Text('dialog'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await Zharp.flush();
      expect(backend.spans.map((s) => s['name']), ['screen /']);
      await Zharp.close();
    });
  });

  group('lifecycle', () {
    testWidgets('going to the background sends what is queued', (tester) async {
      await Zharp.init(options());
      Zharp.log.info('before pause');
      expect(backend.requests, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.logs.single['body'], {'stringValue': 'before pause'});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Zharp.close();
    });

    test('clearUser starts a new session', () async {
      await Zharp.init(options());
      final first = Zharp.sessionId;
      Zharp.clearUser();
      expect(Zharp.sessionId, isNot(first));
    });
  });
}

class _LoadsOnOpen extends StatefulWidget {
  const _LoadsOnOpen(this.api);
  final http.Client api;

  @override
  State<_LoadsOnOpen> createState() => _LoadsOnOpenState();
}

class _LoadsOnOpenState extends State<_LoadsOnOpen> {
  @override
  void initState() {
    super.initState();
    widget.api.get(Uri.parse('https://api.shop.test/cart'));
  }

  @override
  Widget build(BuildContext context) => const Text('cart');
}
