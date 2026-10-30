import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zharp_core/zharp_core.dart';
import 'package:zharp_dio/zharp_dio.dart';

/// Answers every request with [status] (or fails it when [fail]), remembering what it was sent.
class FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> seen = [];
  int status = 200;
  bool fail = false;

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    if (fail) throw const SocketException('unreachable');
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late List<http.Request> sent;
  late FakeAdapter adapter;
  late Dio dio;

  List<Map<String, dynamic>> spans() => [
        for (final r in sent.where((r) => r.url.path.endsWith('/v1/traces')))
          for (final rs in (jsonDecode(utf8.decode(gzip.decode(r.bodyBytes)))['resourceSpans'] as List))
            for (final ss in rs['scopeSpans'] as List) ...(ss['spans'] as List).cast<Map<String, dynamic>>(),
      ];
  Map<String, Object?> attrs(Map<String, dynamic> span) => {
        for (final kv in span['attributes'] as List) kv['key'] as String: (kv['value'] as Map).values.first,
      };

  setUp(() {
    sent = [];
    adapter = FakeAdapter();
    dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(ZharpDioInterceptor());
    ZharpCore.start(ZharpOptions(
      key: 'zpk_test',
      service: 'shop-app',
      endpoint: 'https://ingest.test/api/v1/otlp',
      tracingOrigins: ['api.shop.test'],
      httpClient: MockClient((request) async {
        sent.add(request);
        return http.Response('{}', 200);
      }),
    ));
  });
  tearDown(() async => ZharpCore.instance?.close());

  test('a CLIENT span per request, under the current span, with trace headers for tracingOrigins', () async {
    final zharp = ZharpCore.instance!;
    zharp.setUser(id: 'u-1');
    await zharp.startSpan('checkout', (_) async {
      await dio.get<dynamic>('https://api.shop.test/orders', options: Options(headers: {'baggage': 'team=core'}));
      await dio.get<dynamic>('https://cdn.other.test/logo.png');
    });
    await zharp.flush();

    final ours = adapter.seen[0].headers;
    final parsed = parseTraceparent(ours['traceparent'] as String)!;
    expect(
        parseBaggage(ours['baggage'] as String), {'team': 'core', 'session.id': zharp.session.id, 'enduser.id': 'u-1'});
    expect(adapter.seen[1].headers.containsKey('traceparent'), isFalse);

    final byName = {for (final s in spans()) s['name']: s};
    final get = byName['GET api.shop.test/orders']!;
    expect(get['kind'], 3);
    expect(get['spanId'], parsed.spanId);
    expect(get['parentSpanId'], byName['checkout']!['spanId']);
    expect(attrs(get)['http.response.status_code'], '200');
    expect(attrs(get)['http.request.method'], 'GET');
    expect(byName.containsKey('GET cdn.other.test/logo.png'), isTrue);
  });

  test('HTTP errors and network failures end the span as an error; the app still gets them', () async {
    adapter.status = 500;
    await expectLater(dio.get<dynamic>('https://api.shop.test/a'), throwsA(isA<DioException>()));
    adapter.fail = true;
    await expectLater(dio.get<dynamic>('https://api.shop.test/b'), throwsA(isA<DioException>()));
    await ZharpCore.instance!.flush();
    final byName = {for (final s in spans()) s['name']: s};
    expect(byName['GET api.shop.test/a']!['status']['code'], 2);
    expect(attrs(byName['GET api.shop.test/a']!)['http.response.status_code'], '500');
    final failed = byName['GET api.shop.test/b']!;
    expect(failed['status']['code'], 2);
    // A raw adapter failure is `unknown` to Dio; its real adapter reports connectionError.
    expect(attrs(failed)['dio.exception.type'], 'unknown');
  });

  test('passes requests through untouched when Zharp is not running', () async {
    await ZharpCore.instance!.close();
    final response = await dio.get<dynamic>('https://api.shop.test/x');
    expect(response.statusCode, 200);
    expect(adapter.seen.single.headers.containsKey('traceparent'), isFalse);
  });
}
