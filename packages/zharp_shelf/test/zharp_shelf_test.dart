import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';
import 'package:zharp_core/zharp_core.dart';
import 'package:zharp_shelf/zharp_shelf.dart';

import 'fake_backend.dart';

final RegExp _stamp = RegExp(r'\s*\btrace_id=([0-9a-f]{32})\s+span_id=([0-9a-f]{16})\s*$', caseSensitive: false);

void main() {
  late FakeBackend backend;
  late HttpServer server;
  late List<String> printed;
  late ZharpCore zharp;
  late Uri base;

  setUp(() async {
    backend = FakeBackend();
    printed = [];
    resetOutputCapture();
    zharp = ZharpCore.start(ZharpOptions(
      key: 'zpk_test',
      service: 'api',
      endpoint: 'https://ingest.test/api/v1/otlp',
      httpClient: backend.client,
    ))!;

    final gate = Completer<void>();
    final router = Router()
      ..get('/users/<id>', (Request request, String id) {
        setRequestRoute('/users/<id>');
        print('loading user $id');
        zharp.log.info('user $id');
        return Response.ok('user $id');
      })
      ..get('/slow/<who>', (Request request, String who) async {
        zharp.setUser(id: who);
        if (who == 'a') await gate.future;
        print('done $who');
        if (who == 'b') gate.complete();
        return Response.ok(who);
      })
      ..get('/boom', (Request request) => throw StateError('cart is empty'))
      ..get('/fail', (Request request) => Response.internalServerError());
    final handler = const Pipeline().addMiddleware(zharpMiddleware()).addHandler(router.call);
    // shelf_io logs the errors it answers with a 500; keep them out of the test output.
    server = await runZoned(
      () => shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0),
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
    );
    base = Uri.parse('http://127.0.0.1:${server.port}');
  });
  tearDown(() async {
    await server.close(force: true);
    await zharp.close();
  });

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await zharp.flush();
  }

  Map<String, Object?> attributesOf(Map<String, dynamic> record) => attrs(record['attributes'] as List);

  test('a SERVER span per request, named by its route, with the line printed in it stamped', () async {
    final response = await http.get(base.resolve('/users/42?api_key=k'), headers: {'user-agent': 'tests/1.0'});
    expect(response.body, 'user 42');
    await settle();
    final span = backend.spans.single;
    expect(span['name'], 'GET /users/<id>');
    expect(span['kind'], SpanKind.server.code);
    final a = attributesOf(span);
    expect(a['http.route'], '/users/<id>');
    expect(a['url.path'], '/users/42');
    expect(a['url.query'], 'api_key=[Filtered]');
    expect(a['http.response.status_code'], 200);
    expect(a['client.address'], '127.0.0.1');
    expect(a['user_agent.original'], 'tests/1.0');
    final line = printed.singleWhere((l) => l.startsWith('loading user 42'));
    expect(_stamp.firstMatch(line)!.group(2), span['spanId']);
    expect(backend.logs.single['spanId'], span['spanId']);
  });

  test("continues the caller's trace, with baggage's session and user", () async {
    const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
    await http.get(base.resolve('/users/7'), headers: {
      'traceparent': '00-$traceId-00f067aa0ba902b7-01',
      'baggage': 'session.id=s-9,enduser.id=u-1',
    });
    await settle();
    final span = backend.spans.single;
    expect(span['traceId'], traceId);
    expect(span['parentSpanId'], '00f067aa0ba902b7');
    expect(attributesOf(span), allOf(containsPair('session.id', 's-9'), containsPair('enduser.id', 'u-1')));
    expect(attributesOf(backend.logs.single), containsPair('session.id', 's-9'));
  });

  test('a thrown error: span failed with 500, the error reported in its trace; shelf still answers 500', () async {
    final response = await http.get(base.resolve('/boom'));
    expect(response.statusCode, 500);
    await settle();
    final span = backend.spans.single;
    expect(span['name'], 'GET /boom');
    expect(span['status']['code'], 2);
    expect(attributesOf(span), allOf(containsPair('http.response.status_code', 500), containsPair('error.type', 'StateError')));
    final error = backend.logs.single;
    expect(error['traceId'], span['traceId']);
    expect(attributesOf(error), containsPair('exception.type', 'StateError'));
  });

  test('a 5xx response marks the span failed', () async {
    expect((await http.get(base.resolve('/fail'))).statusCode, 500);
    await settle();
    expect(backend.spans.single['status']['code'], 2);
    expect(attributesOf(backend.spans.single)['error.type'], '500');
  });

  test("concurrent requests don't mix their span, user or stamp", () async {
    final a = http.get(base.resolve('/slow/a'));
    final b = http.get(base.resolve('/slow/b'));
    await Future.wait([a, b]);
    await settle();
    final spans = {for (final s in backend.spans) s['url'] ?? attributesOf(s)['url.path']: s};
    for (final who in ['a', 'b']) {
      final span = spans['/slow/$who']!;
      expect(attributesOf(span)['enduser.id'], who);
      final line = printed.singleWhere((l) => l.startsWith('done $who'));
      expect(_stamp.firstMatch(line)!.group(2), span['spanId']);
    }
  });
}
