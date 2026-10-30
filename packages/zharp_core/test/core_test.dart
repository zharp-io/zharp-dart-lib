import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zharp_core/zharp_core.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());
  tearDown(() async => ZharpCore.instance?.close());

  ZharpCore start({List<Pattern> tracingOrigins = const [], double sampleRate = 1.0, DateTime Function()? clock}) =>
      ZharpCore.start(
          clock: clock,
          ZharpOptions(
            key: 'zpk_test',
            service: 'shop-app',
            environment: 'production',
            release: 'shop@1.2.0',
            endpoint: 'https://ingest.test/api/v1/otlp/',
            tracingOrigins: tracingOrigins,
            sampleRate: sampleRate,
            httpClient: backend.client,
          ))!;

  group('start', () {
    test('without a key or when disabled nothing runs', () {
      expect(ZharpCore.start(const ZharpOptions(key: ' ')), isNull);
      expect(ZharpCore.start(const ZharpOptions(key: 'zpk_x', enabled: false)), isNull);
      expect(ZharpCore.instance, isNull);
    });

    test('the resource names the service, release, environment and SDK', () async {
      final zharp = start();
      zharp.log.info('hello');
      await zharp.flush();
      final resource = backend.resourceOf(backend.requests.single);
      expect(resource, containsPair('service.name', 'shop-app'));
      expect(resource, containsPair('service.version', 'shop@1.2.0'));
      expect(resource, containsPair('deployment.environment.name', 'production'));
      expect(resource, containsPair('telemetry.sdk.name', 'zharp'));
      expect(resource, containsPair('telemetry.sdk.language', 'dart'));
      expect(resource, containsPair('telemetry.sdk.version', sdkVersion));
      expect(resource['os.name'], isNotNull);
      expect(backend.requests.single.url.toString(), 'https://ingest.test/api/v1/otlp/v1/logs');
    });
  });

  test('updateResource adds late device context; options keep priority', () async {
    final zharp = start();
    zharp.updateResource({'device.model.name': 'Pixel 8', 'service.name': 'nope'}, defaultRelease: 'app@9');
    zharp.log.info('x');
    await zharp.flush();
    final resource = backend.resourceOf(backend.requests.single);
    expect(resource['device.model.name'], 'Pixel 8');
    expect(resource['service.name'], 'shop-app');
    expect(resource['service.version'], 'shop@1.2.0');
  });

  group('logs', () {
    test('carry severity, body, attributes, the session, user and tags', () async {
      final zharp = start();
      zharp.setUser(id: 'u-42', email: 'a@b.test');
      zharp.setTag('plan', 'pro');
      zharp.log.warn('Low stock', {'sku': 'A1', 'left': 2});
      await zharp.flush();
      final log = backend.logs.single;
      expect(log['severityNumber'], 13);
      expect(log['severityText'], 'WARN');
      expect(log['body'], {'stringValue': 'Low stock'});
      final a = attrs(log['attributes'] as List);
      expect(a, containsPair('sku', 'A1'));
      expect(a, containsPair('left', 2));
      expect(a, containsPair('enduser.id', 'u-42'));
      expect(a, containsPair('enduser.email', 'a@b.test'));
      expect(a, containsPair('plan', 'pro'));
      expect(a['session.id'], zharp.session.id);
      expect(log.containsKey('traceId'), isFalse);
    });

    test('inside a span they carry its trace and span IDs', () async {
      final zharp = start();
      late ZharpSpan span;
      await zharp.startSpan('checkout', (s) async {
        span = s;
        await Future<void>.delayed(Duration.zero);
        zharp.log.info('inside');
      });
      await zharp.flush();
      final log = backend.logs.single;
      expect(log['traceId'], span.traceId);
      expect(log['spanId'], span.spanId);
    });

    test('clearUser forgets the user and starts a new session', () async {
      final zharp = start();
      zharp.setUser(id: 'u-1');
      final first = zharp.session.id;
      zharp.clearUser();
      zharp.log.info('after');
      await zharp.flush();
      final a = attrs(backend.logs.single['attributes'] as List);
      expect(a.containsKey('enduser.id'), isFalse);
      expect(a['session.id'], isNot(first));
    });
  });

  group('errors', () {
    test('captureError: an ERROR log with exception attributes, handled', () async {
      final zharp = start();
      try {
        throw StateError('cart is empty');
      } catch (e, st) {
        zharp.captureError(e, stackTrace: st, attributes: {'order': 7});
      }
      await zharp.flush();
      final log = backend.logs.single;
      expect(log['severityNumber'], 17);
      final a = attrs(log['attributes'] as List);
      expect(a['exception.type'], 'StateError');
      expect(a['exception.message'], 'Bad state: cart is empty');
      expect((a['exception.stacktrace'] as String).split('\n').first, 'StateError: Bad state: cart is empty');
      expect(a['exception.stacktrace'], contains('core_test.dart'));
      expect(a['zharp.handled'], 'true');
      expect(a['order'], 7);
    });

    test('uncaught errors are handled=false; the same error object is reported once', () async {
      final zharp = start();
      final error = ArgumentError('bad');
      zharp.captureError(error, handled: false);
      zharp.captureError(error);
      await zharp.flush();
      expect(backend.logs, hasLength(1));
      expect(attrs(backend.logs.single['attributes'] as List)['zharp.handled'], 'false');
    });

    test('the same error from the same place within a second is sent once', () {
      fakeAsync((async) {
        final base = DateTime.utc(2026);
        final zharp = start(clock: () => base.add(async.elapsed));
        for (var i = 0; i < 50; i++) {
          zharp.captureError('render failed', stackTrace: StackTrace.fromString('#0 build (package:app/a.dart:1:1)'));
        }
        async.elapse(const Duration(seconds: 2));
        zharp.captureError('render failed', stackTrace: StackTrace.fromString('#0 build (package:app/a.dart:1:1)'));
        async.elapse(const Duration(seconds: 6));
        expect(backend.logs, hasLength(2));
      });
    });

    test('Zharp.log.error(e) with an error reports it as one', () async {
      final zharp = start();
      zharp.log.error(const FormatException('bad json'));
      await zharp.flush();
      expect(attrs(backend.logs.single['attributes'] as List)['exception.type'], 'FormatException');
    });
  });

  group('spans', () {
    test('startSpan: children (across await) share the trace; a throw is an unhandled exception event', () async {
      final zharp = start();
      await expectLater(
        zharp.startSpan('checkout', (_) async {
          await zharp.startSpan('validate', (_) async => Future<void>.delayed(Duration.zero));
          throw StateError('payment declined');
        }),
        throwsStateError,
      );
      await zharp.flush();
      final spans = {for (final s in backend.spans) s['name']: s};
      final parent = spans['checkout']!;
      final child = spans['validate']!;
      expect(child['traceId'], parent['traceId']);
      expect(child['parentSpanId'], parent['spanId']);
      expect(parent.containsKey('parentSpanId'), isFalse);
      expect(parent['status']['code'], 2);
      final event = (parent['events'] as List).single;
      expect(event['name'], 'exception');
      final a = attrs(event['attributes'] as List);
      expect(a['exception.type'], 'StateError');
      expect(a['zharp.handled'], 'false');
      expect(attrs(parent['attributes'] as List)['session.id'], zharp.session.id);
    });

    test('startSpan returns the body\'s value, sync or async', () async {
      final zharp = start();
      expect(zharp.startSpan('sync', (_) => 3), 3);
      expect(await zharp.startSpan('async', (_) async => 'x'), 'x');
    });

    test('sampleRate 0 sends no spans but still sends errors and logs', () async {
      final zharp = start(sampleRate: 0);
      zharp.startSpan('dropped', (_) => zharp.captureError(StateError('kept')));
      await zharp.flush();
      expect(backend.spans, isEmpty);
      expect(backend.logs, hasLength(1));
      expect(backend.logs.single['traceId'], isNotNull);
    });

    test('an idle (screen) span waits for its requests, then ends at the last one', () {
      fakeAsync((async) {
        final base = DateTime.utc(2026);
        final zharp = start(clock: () => base.add(async.elapsed));
        final screen = zharp.tracer.startIdle('screen /cart',
            idleTimeout: const Duration(seconds: 1), maxDuration: const Duration(seconds: 30));
        final release = screen.hold();
        async.elapse(const Duration(milliseconds: 100));
        release();
        final request = zharp.tracer.start('GET api/cart', kind: SpanKind.client);
        expect(request.parentSpanId, screen.span.spanId);
        async.elapse(const Duration(seconds: 3));
        expect(screen.span.isEnded, isFalse);
        request.end();
        async.elapse(const Duration(milliseconds: 999));
        expect(screen.span.isEnded, isFalse);
        async.elapse(const Duration(milliseconds: 2));
        expect(screen.span.isEnded, isTrue);
        // Ends when the request did, not after the idle wait.
        expect(screen.span.endMicros, request.endMicros);
        // After it ended, new work starts its own trace.
        expect(zharp.tracer.start('later').parentSpanId, isNull);
      });
    });

    test('a new screen ends the previous one; maxDuration caps a busy one', () {
      fakeAsync((async) {
        final zharp = start();
        final a = zharp.tracer
            .startIdle('screen /a', idleTimeout: const Duration(seconds: 1), maxDuration: const Duration(seconds: 30));
        a.hold();
        final b = zharp.tracer
            .startIdle('screen /b', idleTimeout: const Duration(seconds: 1), maxDuration: const Duration(seconds: 30));
        expect(a.span.isEnded, isTrue);
        expect(a.span.attributes['zharp.span.end_reason'], 'replaced');
        b.hold();
        async.elapse(const Duration(seconds: 31));
        expect(b.span.isEnded, isTrue);
        expect(b.span.attributes['zharp.span.end_reason'], 'max_duration');
      });
    });
  });

  group('ZharpHttpClient', () {
    late List<http.Request> seen;
    late http.Client app;

    setUp(() {
      seen = [];
      app = MockClient((request) async {
        seen.add(request);
        return http.Response('ok', request.url.path == '/missing' ? 404 : 200);
      });
    });

    test('a CLIENT span per request, with trace headers only for tracingOrigins', () async {
      final zharp = start(tracingOrigins: ['api.shop.test']);
      zharp.setUser(id: 'u-9');
      final client = ZharpHttpClient(app);
      await zharp.startSpan('screen', (_) async {
        await client.get(Uri.parse('https://api.shop.test/orders?token=secret&page=2'));
        await client.get(Uri.parse('https://cdn.other.test/missing'));
      });
      await zharp.flush();

      final ours = seen[0];
      final parsed = parseTraceparent(ours.headers['traceparent'])!;
      expect(parseBaggage(ours.headers['baggage']), {'session.id': zharp.session.id, 'enduser.id': 'u-9'});
      expect(seen[1].headers.containsKey('traceparent'), isFalse);
      expect(seen[1].headers.containsKey('baggage'), isFalse);

      final spans = {for (final s in backend.spans) s['name']: s};
      final get = spans['GET api.shop.test/orders']!;
      expect(get['kind'], 3);
      expect(get['spanId'], parsed.spanId);
      expect(get['traceId'], parsed.traceId);
      expect(get['parentSpanId'], spans['screen']!['spanId']);
      final a = attrs(get['attributes'] as List);
      expect(a['http.request.method'], 'GET');
      expect(a['http.response.status_code'], 200);
      expect(a['url.full'], 'https://api.shop.test/orders?token=[Filtered]&page=2');
      expect(a['server.address'], 'api.shop.test');

      final missing = spans['GET cdn.other.test/missing']!;
      expect(missing['status']['code'], 2);
      expect(attrs(missing['attributes'] as List)['http.response.status_code'], 404);
    });

    test('a traceparent the app set is kept; its baggage is merged', () async {
      final zharp = start(tracingOrigins: ['api.shop.test']);
      final client = ZharpHttpClient(app);
      final own = formatTraceparent('c' * 32, 'd' * 16, sampled: true);
      await client.get(Uri.parse('https://api.shop.test/x'), headers: {'traceparent': own, 'baggage': 'team=core'});
      expect(seen.single.headers['traceparent'], own);
      expect(seen.single.headers['baggage'], isNot(contains('session.id')));
      await zharp.flush();
    });

    test('network failures end the span as an error and still reach the app', () async {
      final zharp = start();
      final client = ZharpHttpClient(MockClient((_) async => throw http.ClientException('refused')));
      await expectLater(client.get(Uri.parse('https://api.shop.test/x')), throwsA(isA<http.ClientException>()));
      await zharp.flush();
      final span = backend.spans.single;
      expect(span['status']['code'], 2);
      expect(attrs(span['attributes'] as List)['error.type'], 'ClientException');
    });

    test('requests to Zharp itself are not traced; before start everything passes through', () async {
      final client = ZharpHttpClient(app);
      await client.get(Uri.parse('https://api.shop.test/x'));
      final zharp = start(tracingOrigins: ['ingest.test']);
      await client.get(Uri.parse('https://ingest.test/api/v1/otlp/v1/logs'));
      expect(seen.every((r) => !r.headers.containsKey('traceparent')), isTrue);
      await zharp.flush();
      expect(backend.spans, isEmpty);
    });
  });

  test('nothing throws into the app, even with odd input', () async {
    final zharp = start();
    zharp.setTag('', null);
    zharp.setUser(id: '');
    zharp.log.info(null, {'x': Object()});
    zharp.captureError(42);
    final span = zharp.tracer.start('');
    span.end();
    span.end();
    span.setAttribute('after', 'end');
    await zharp.close();
    zharp.log.info('after close');
    zharp.captureError(StateError('after close'));
  });
}
