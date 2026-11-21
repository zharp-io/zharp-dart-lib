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
  String body = '{}';
  List<int>? bytes;
  String contentType = 'application/json';

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    if (fail) throw const SocketException('unreachable');
    if (bytes != null) {
      return ResponseBody.fromBytes(bytes!, status, headers: {
        Headers.contentTypeHeader: [contentType],
      });
    }
    return ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [contentType],
      'x-request-id': ['req-7'],
      'set-cookie': ['sid=secret'],
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

  test('headers by default: what went out and came back, secrets [Filtered]', () async {
    adapter.status = 503;
    await dio.get<dynamic>('https://api.shop.test/orders',
        options: Options(headers: {'Authorization': 'Bearer user-token', 'X-Client': 'flutter'}, validateStatus: (_) => true));
    await ZharpCore.instance!.flush();
    final a = attrs(spans().single);
    expect(a['http.request.header.authorization'], '[Filtered]');
    expect(a['http.request.header.x-client'], 'flutter');
    expect(a['http.request.header.traceparent'], isNotNull, reason: 'the trace headers that went out');
    expect(a['http.response.header.x-request-id'], 'req-7');
    expect(a['http.response.header.set-cookie'], '[Filtered]');
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

  test('tracing: false — no span and no trace headers; the request still goes through', () async {
    await ZharpCore.instance!.close();
    ZharpCore.start(ZharpOptions(
      key: 'zpk_test',
      endpoint: 'https://ingest.test/api/v1/otlp',
      tracing: false,
      tracingOrigins: ['api.shop.test'],
      httpClient: MockClient((request) async {
        sent.add(request);
        return http.Response('{}', 200);
      }),
    ));
    final response = await dio.get<dynamic>('https://api.shop.test/orders');
    expect(response.statusCode, 200);
    ZharpCore.instance!.log.info('still logged');
    await ZharpCore.instance!.flush();
    expect(adapter.seen.single.headers.containsKey('traceparent'), isFalse);
    expect(adapter.seen.single.headers.containsKey('baggage'), isFalse);
    expect(spans(), isEmpty);
    expect(sent.where((r) => r.url.path.endsWith('/v1/logs')), hasLength(1));
  });

  group('captureBodies', () {
    Future<void> restart(CaptureBodies capture) async {
      await ZharpCore.instance!.close();
      ZharpCore.start(ZharpOptions(
        key: 'zpk_test',
        endpoint: 'https://ingest.test/api/v1/otlp',
        captureBodies: capture,
        httpClient: MockClient((request) async {
          sent.add(request);
          return http.Response('{}', 200);
        }),
      ));
    }

    Map<String, Object?> named(String name) => attrs(spans().firstWhere((s) => s['name'] == name));

    test('errors: JSON both ways on a failed request, secrets filtered; successes carry nothing', () async {
      await restart(const CaptureBodies());
      adapter
        ..status = 401
        ..body = '{"error":"bad credentials","token":"leaked","card":{"brand":"visa","last4":"4242"}}';
      await expectLater(dio.post<dynamic>('https://api.shop.test/login', data: {'email': 'a@b.test', 'password': 'hunter2'}),
          throwsA(isA<DioException>()));
      adapter
        ..status = 200
        ..body = '{"saved":true}';
      await dio.put<dynamic>('https://api.shop.test/ok', data: {'name': 'Ada'});
      await ZharpCore.instance!.flush();

      final login = named('POST api.shop.test/login');
      expect(jsonDecode(login['http.request.body'] as String), {'email': 'a@b.test', 'password': '[Filtered]'});
      expect(jsonDecode(login['http.response.body'] as String),
          {'error': 'bad credentials', 'token': '[Filtered]', 'card': {'brand': '[Filtered]', 'last4': '[Filtered]'}});
      expect(login['http.response.header.content-type'], 'application/json');
      expect(named('PUT api.shop.test/ok').containsKey('http.request.body'), isFalse);
    });

    test('FormData: every field by name, files described, the password filtered', () async {
      await restart(const CaptureBodies.all());
      final form = FormData.fromMap({
        'title': 'Holiday',
        'password': 'form-secret',
        'photo': MultipartFile.fromBytes(List.filled(2048, 1), filename: 'photo.png', contentType: DioMediaType('image', 'png')),
      });
      await dio.post<dynamic>('https://api.shop.test/upload', data: form);
      await ZharpCore.instance!.flush();
      final upload = named('POST api.shop.test/upload');
      expect(jsonDecode(upload['http.request.body'] as String),
          {'title': 'Holiday', 'password': '[Filtered]', 'photo': '[file photo.png · image/png · 2 KB]'});
      expect(upload['http.request.header.content-type'], 'multipart/form-data');
    });

    test('form-urlencoded maps, binary responses described, no response keeps the request body', () async {
      await restart(const CaptureBodies.all());
      await dio.post<dynamic>('https://api.shop.test/form',
          data: {'user': 'ada', 'password': 'p4ss'}, options: Options(contentType: Headers.formUrlEncodedContentType));
      adapter
        ..bytes = List.filled(3000, 7)
        ..contentType = 'image/png';
      await dio.get<dynamic>('https://api.shop.test/image', options: Options(responseType: ResponseType.bytes));
      adapter.fail = true;
      await expectLater(dio.post<dynamic>('https://api.shop.test/pay', data: {'amount': 5, 'cvv': '123'}), throwsA(isA<DioException>()));
      await ZharpCore.instance!.flush();
      expect(named('POST api.shop.test/form')['http.request.body'], 'user=ada&password=[Filtered]');
      expect(named('GET api.shop.test/image')['http.response.body'], '[binary · image/png · 3 KB]');
      expect(named('POST api.shop.test/pay')['http.request.body'], '{"amount":5,"cvv":"[Filtered]"}');
    });

    test('secret query values are filtered in url.full', () async {
      await dio.get<dynamic>('https://api.shop.test/x?token=abc&page=2');
      await ZharpCore.instance!.flush();
      expect(named('GET api.shop.test/x')['url.full'], 'https://api.shop.test/x?token=[Filtered]&page=2');
    });
  });
}
