import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zharp_core/server.dart';
import 'package:zharp_core/zharp_core.dart';

import 'fake_backend.dart';

final RegExp _stamp = RegExp(r'\s*\btrace_id=([0-9a-f]{32})\s+span_id=([0-9a-f]{16})\s*$', caseSensitive: false);

void main() {
  late FakeBackend backend;
  late HttpServer server;
  late List<String> printed;
  late List<Object> uncaught;
  late Uri base;

  setUp(() {
    backend = FakeBackend();
    printed = [];
    uncaught = [];
    resetOutputCapture();
  });
  tearDown(() async {
    await server.close(force: true);
    await ZharpCore.instance?.close();
  });

  ZharpCore start({double sampleRate = 1.0, bool tracing = true, List<Pattern> tracingOrigins = const []}) =>
      ZharpCore.start(ZharpOptions(
        key: 'zpk_test',
        service: 'api',
        endpoint: 'https://ingest.test/api/v1/otlp',
        httpClient: backend.client,
        sampleRate: sampleRate,
        tracing: tracing,
        tracingOrigins: tracingOrigins,
      ))!;

  /// A server whose handler is wrapped in zharpHandler; what it prints goes to [printed], its
  /// uncaught errors to [uncaught].
  Future<void> serve(Future<void> Function(HttpRequest request) handler) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    runZonedGuarded(
      () => server.listen(zharpHandler(handler)),
      (error, _) => uncaught.add(error),
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
    );
  }

  Future<(int, String)> get(String path, {Map<String, String> headers = const {}}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(base.resolve(path));
      headers.forEach(request.headers.set);
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> settle(ZharpCore zharp) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await zharp.flush();
  }

  Map<String, Object?> attributesOf(Map<String, dynamic> record) => attrs(record['attributes'] as List);

  test('one SERVER span per request: name, attributes, status', () async {
    final zharp = start();
    await serve((request) async {
      request.response.statusCode = request.uri.path == '/missing' ? 404 : 200;
      request.response.write('ok');
      await request.response.close();
    });
    expect((await get('/orders?id=7&token=s3cret', headers: {'user-agent': 'tests/1.0'})).$1, 200);
    expect((await get('/missing')).$1, 404);
    await settle(zharp);

    final spans = backend.spans;
    expect([for (final s in spans) s['name']], ['GET /orders', 'GET /missing']);
    final first = spans.first;
    expect(first['kind'], SpanKind.server.code);
    expect(first['parentSpanId'], anyOf(isNull, isEmpty));
    final a = attributesOf(first);
    expect(a['http.request.method'], 'GET');
    expect(a['url.path'], '/orders');
    expect(a['url.query'], 'id=7&token=[Filtered]');
    expect(a['http.response.status_code'], 200);
    expect(a['server.address'], '127.0.0.1');
    expect(a['client.address'], '127.0.0.1');
    expect(a['user_agent.original'], 'tests/1.0');
    expect(a.containsKey('session.id'), isFalse, reason: 'a server has no session of its own');
    // A 404 is the caller's failure, not the server's.
    expect(spans.last['status']?['code'], isNot(2));
  });

  test("continues the caller's trace; baggage's session and user are on the span and logs", () async {
    final zharp = start();
    await serve((request) async {
      zharp.log.info('handling');
      await request.response.close();
    });
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    const parentId = 'b7ad6b7169203331';
    await get('/cart', headers: {
      'traceparent': '00-$traceId-$parentId-01',
      'baggage': 'session.id=sess-1,enduser.id=42,other=x',
    });
    await settle(zharp);
    final span = backend.spans.single;
    expect(span['traceId'], traceId);
    expect(span['parentSpanId'], parentId);
    expect(attributesOf(span), allOf(containsPair('session.id', 'sess-1'), containsPair('enduser.id', '42')));
    expect(attributesOf(span).containsKey('other'), isFalse);
    final log = backend.logs.single;
    expect(log['traceId'], traceId);
    expect(log['spanId'], span['spanId']);
    expect(attributesOf(log), allOf(containsPair('session.id', 'sess-1'), containsPair('enduser.id', '42')));
  });

  test("a caller's unsampled trace isn't sent, but lines printed in it are still stamped", () async {
    final zharp = start();
    await serve((request) async {
      print('working');
      await request.response.close();
    });
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    await get('/x', headers: {'traceparent': '00-$traceId-b7ad6b7169203331-00'});
    await settle(zharp);
    expect(backend.spans, isEmpty);
    expect(_stamp.firstMatch(printed.single)!.group(1), traceId);
  });

  test('sampleRate 0: no spans sent, lines still stamped', () async {
    final zharp = start(sampleRate: 0);
    await serve((request) async {
      print('working');
      await request.response.close();
    });
    await get('/x');
    await settle(zharp);
    expect(backend.spans, isEmpty);
    expect(_stamp.hasMatch(printed.single), isTrue);
  });

  test("print inside the handler ends with the request span's ids", () async {
    final zharp = start();
    await serve((request) async {
      print('loading orders');
      stdout.writeln('stdout too');
      await request.response.close();
    });
    await get('/orders');
    await settle(zharp);
    final span = backend.spans.single;
    final match = _stamp.firstMatch(printed.single)!;
    expect(printed.single, startsWith('loading orders trace_id='));
    expect(match.group(1), span['traceId']);
    expect(match.group(2), span['spanId']);
  });

  test('a thrown error marks the span, is reported in its trace, and still reaches the zone', () async {
    final zharp = start();
    await serve((request) async {
      request.response.statusCode = 500;
      unawaited(request.response.close());
      throw StateError('cart is empty');
    });
    expect((await get('/checkout')).$1, 500);
    await settle(zharp);
    final span = backend.spans.single;
    expect(span['status']['code'], 2);
    expect(attributesOf(span)['error.type'], 'StateError');
    final error = backend.logs.single;
    expect(error['severityText'], 'ERROR');
    expect(error['traceId'], span['traceId']);
    expect(attributesOf(error), allOf(containsPair('exception.type', 'StateError'), containsPair('zharp.handled', 'false')));
    expect(uncaught.single, isA<StateError>());
  });

  test("concurrent requests keep their own span, user and stamp", () async {
    final zharp = start();
    final gate = Completer<void>();
    await serve((request) async {
      final who = request.uri.path.substring(1);
      zharp.setUser(id: who);
      if (who == 'a') await gate.future; // a waits until b has finished
      await Future<void>.delayed(const Duration(milliseconds: 5));
      print('done $who');
      zharp.log.info('log $who');
      await request.response.close();
    });
    final a = get('/a');
    await get('/b');
    gate.complete();
    await a;
    await settle(zharp);

    final spans = {for (final s in backend.spans) s['name']: s};
    for (final who in ['a', 'b']) {
      final span = spans['GET /$who']!;
      expect(attributesOf(span)['enduser.id'], who);
      final line = printed.singleWhere((l) => l.startsWith('done $who'));
      expect(_stamp.firstMatch(line)!.group(2), span['spanId']);
      final log = backend.logs.singleWhere((l) => l['body']['stringValue'] == 'log $who');
      expect(log['spanId'], span['spanId']);
      expect(attributesOf(log)['enduser.id'], who);
    }
    expect(zharp.user, isNull, reason: "a request's user is not the process's");
  });

  test('outgoing traced requests made while handling are children, and carry the trace on', () async {
    final zharp = start(tracingOrigins: ['127.0.0.1']);
    final client = ZharpHttpClient();
    await serve((request) async {
      if (request.uri.path == '/front') {
        final response = await client.get(base.resolve('/back'));
        request.response.write(response.body);
      } else {
        request.response.write('back');
      }
      await request.response.close();
    });
    await get('/front');
    await settle(zharp);
    client.close();
    final byName = {for (final s in backend.spans) s['name'] as String: s};
    final front = byName['GET /front']!;
    final call = byName.entries.firstWhere((e) => e.value['kind'] == SpanKind.client.code).value;
    final back = byName['GET /back']!;
    expect(call['parentSpanId'], front['spanId']);
    expect(back['parentSpanId'], call['spanId']);
    expect({front['traceId'], call['traceId'], back['traceId']}, hasLength(1));
  });

  test('logs only (tracing: false): no spans; a traceparent still puts logs and lines in its trace', () async {
    final zharp = start(tracing: false);
    await serve((request) async {
      zharp.log.info('handling');
      print('line');
      await request.response.close();
    });
    const traceId = '0af7651916cd43dd8448eb211c80319c';
    await get('/x', headers: {'traceparent': '00-$traceId-b7ad6b7169203331-01'});
    await get('/y');
    await settle(zharp);
    expect(backend.spans, isEmpty);
    expect(backend.logs.first['traceId'], traceId);
    expect(_stamp.firstMatch(printed.first)!.group(1), traceId);
    expect(printed.last, 'line');
  });

  test('before Zharp starts, the handler runs untouched', () async {
    await serve((request) async {
      print('plain');
      await request.response.close();
    });
    expect((await get('/x')).$1, 200);
    expect(printed, ['plain']);
  });
}
