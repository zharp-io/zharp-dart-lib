import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zharp_logs/src/message.dart';
import 'package:zharp_logs/src/transport.dart';
import 'package:zharp_logs/zharp_logs.dart';

/// A fake backend that records what it was sent and answers with [status].
class FakeBackend {
  FakeBackend({this.status = 202});

  int status;
  final List<http.Request> requests = [];

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', status);
  });

  List<Map<String, dynamic>> get logs => [
        for (final r in requests) ...(jsonDecode(r.body)['logs'] as List).cast<Map<String, dynamic>>(),
      ];
}

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());
  tearDown(ZharpLogger.close);

  void start({String? environment, String? appVersion, bool capturePrint = false}) => ZharpLogger.init(
        apiKey: 'key-123',
        service: 'checkout-api',
        environment: environment,
        appVersion: appVersion,
        endpoint: 'https://api.example.test/api/v1/',
        capturePrint: capturePrint,
        httpClient: backend.client,
      );

  group('init', () {
    test('without an API key nothing starts and logs are dropped', () async {
      ZharpLogger.init(service: 'x', httpClient: backend.client);
      expect(ZharpLogger.isActive, isFalse);
      ZharpLogger.error('lost');
      await ZharpLogger.flushAll();
      expect(backend.requests, isEmpty);
    });

    test('with a key it is active', () {
      start();
      expect(ZharpLogger.isActive, isTrue);
    });
  });

  group('what is sent', () {
    test('the request: path, headers and body shape match the JS SDK', () async {
      start(environment: 'production', appVersion: '1.4.2');
      ZharpLogger.info('User signed in', {'userId': 42});
      await ZharpLogger.flushAll();

      expect(backend.requests, hasLength(1));
      final request = backend.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.example.test/api/v1/agent/logs');
      expect(request.headers['x-api-key'], 'key-123');
      expect(request.headers['x-zharp-sdk'], 'dart-logs/$version');
      expect(request.headers['content-type'], startsWith('application/json'));

      final entry = backend.logs.single;
      expect(entry['service'], 'checkout-api');
      expect(entry['level'], 'info');
      expect(entry['message'], 'User signed in');
      expect(DateTime.parse(entry['timestamp'] as String).isUtc, isTrue);
      expect(entry['environment'], 'production');
      expect(entry['version'], '1.4.2');
      expect(entry.containsKey('source'), isFalse, reason: 'unset tags are left out, not sent empty');

      final metadata = entry['metadata'] as Map<String, dynamic>;
      expect(metadata['userId'], 42);
      expect(metadata['sessionId'], ZharpLogger.sessionId);
      expect(metadata['environment'], 'production');
      final context = metadata['context'] as Map<String, dynamic>;
      expect(context['appVersion'], '1.4.2');
      expect(context['platform'], isNotNull);
      expect(context['dartVersion'], isNotNull);
    });

    test('every level, and a log filed under another service', () async {
      start();
      ZharpLogger.debug('d');
      ZharpLogger.info('i');
      ZharpLogger.warn('w');
      ZharpLogger.log(LogLevel.info, 'elsewhere', service: 'payment-service');
      await ZharpLogger.flushAll();
      expect(backend.logs.map((e) => e['level']), ['debug', 'info', 'warn', 'info']);
      expect(backend.logs.last['service'], 'payment-service');
    });

    test('messages that are not text become text; empty ones a placeholder', () async {
      start();
      ZharpLogger.info(null);
      ZharpLogger.info('   ');
      ZharpLogger.info({'a': 1});
      ZharpLogger.info(StateError('bad state'));
      await ZharpLogger.flushAll();
      expect(backend.logs.map((e) => e['message']),
          ['(empty message)', '(empty message)', '{"a":1}', 'Bad state: bad state']);
    });

    test('metadata JSON cannot hold becomes text, and is copied when logged', () async {
      start();
      final metadata = <String, Object?>{'at': DateTime.utc(2026, 1, 2), 'took': const Duration(seconds: 2), 'obj': Object()};
      ZharpLogger.info('m', metadata);
      metadata['at'] = 'changed later';
      await ZharpLogger.flushAll();
      final sent = backend.logs.single['metadata'] as Map<String, dynamic>;
      expect(sent['at'], '2026-01-02T00:00:00.000Z');
      expect(sent['took'], 2000);
      expect(sent['obj'], "Instance of 'Object'");
    });

    test('setContext adds fields to every log context', () async {
      start();
      ZharpLogger.setContext({'userId': 'u-7'});
      ZharpLogger.info('x');
      await ZharpLogger.flushAll();
      ZharpLogger.setContext({});
      expect((backend.logs.single['metadata'] as Map)['context']['userId'], 'u-7');
    });

    test('captureException sends the error, its type and stack', () async {
      start();
      try {
        throw const FormatException('bad input');
      } catch (e, stack) {
        ZharpLogger.captureException(e, stack, metadata: {'orderId': 99});
      }
      await ZharpLogger.flushAll();
      final entry = backend.logs.single;
      expect(entry['level'], 'error');
      expect(entry['message'], 'FormatException: bad input');
      final metadata = entry['metadata'] as Map<String, dynamic>;
      expect(metadata['name'], 'FormatException');
      expect(metadata['stack'], contains('zharp_logs_test.dart'));
      expect(metadata['orderId'], 99);
    });
  });

  group('delivery', () {
    test('info waits for the timer; error goes at once', () async {
      ZharpLogger.init(apiKey: 'k', service: 's', httpClient: backend.client, flushInterval: const Duration(seconds: 30));
      ZharpLogger.info('queued');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.requests, isEmpty, reason: 'info waits for the next flush');
      ZharpLogger.error('now');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.logs.map((e) => e['message']), ['queued', 'now']);
    });

    test('the timer sends what is queued', () async {
      ZharpLogger.init(apiKey: 'k', service: 's', httpClient: backend.client, flushInterval: const Duration(milliseconds: 50));
      ZharpLogger.info('later');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.logs.single['message'], 'later');
    });

    test('batches are capped by maxBatchSize', () async {
      ZharpLogger.init(apiKey: 'k', service: 's', httpClient: backend.client, maxBatchSize: 2);
      for (var i = 0; i < 5; i++) {
        ZharpLogger.info('n$i');
      }
      await ZharpLogger.flushAll();
      expect(backend.requests, hasLength(3));
      expect(backend.logs, hasLength(5));
    });

    test('close sends everything queued and stops logging', () async {
      start();
      ZharpLogger.info('last words');
      await ZharpLogger.close();
      expect(backend.logs.single['message'], 'last words');
      expect(ZharpLogger.isActive, isFalse);
      ZharpLogger.info('after close');
      await ZharpLogger.flushAll();
      expect(backend.logs, hasLength(1));
    });

    test('a second init replaces the first; the old queue still goes out with its own key', () async {
      final second = FakeBackend();
      start();
      ZharpLogger.info('old');
      ZharpLogger.init(apiKey: 'key-2', service: 'other', httpClient: second.client);
      ZharpLogger.info('new');
      await ZharpLogger.flushAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(backend.logs.single['message'], 'old');
      expect(backend.requests.single.headers['x-api-key'], 'key-123');
      expect(second.logs.single['message'], 'new');
    });
  });

  group('transport', () {
    test('5xx and network errors are retried, three attempts in all; 4xx is not', () async {
      var calls = 0;
      final failing = MockClient((_) async {
        calls++;
        return http.Response('', 503);
      });
      final transport = Transport(apiKey: 'k', endpoint: 'https://x', client: failing, retryDelay: const Duration(milliseconds: 1));
      await transport.send([{'message': 'a'}]);
      expect(calls, 3);

      calls = 0;
      final rejecting = MockClient((_) async {
        calls++;
        return http.Response('', 400);
      });
      await Transport(apiKey: 'k', endpoint: 'https://x', client: rejecting, retryDelay: const Duration(milliseconds: 1))
          .send([{'message': 'a'}]);
      expect(calls, 1);

      calls = 0;
      final offline = MockClient((_) async {
        calls++;
        throw http.ClientException('offline');
      });
      await Transport(apiKey: 'k', endpoint: 'https://x', client: offline, retryDelay: const Duration(milliseconds: 1))
          .send([{'message': 'a'}]);
      expect(calls, 3);
    });

    test('bodies are cut by bytes; an oversized entry still goes alone', () {
      final big = {'message': 'x' * 600};
      final bodies = splitBySize([big, big, big], 1300);
      expect(bodies, hasLength(2));
      expect(splitBySize([{'message': 'y' * 5000}], 1000), hasLength(1));
      for (final body in bodies) {
        expect(jsonDecode(body)['logs'], isA<List>());
      }
    });

    test('the endpoint is trimmed and defaults to Zharp', () {
      expect(normalizeEndpoint(null), 'https://api.zharp.io/api/v1');
      expect(normalizeEndpoint('https://x.test/api/v1///'), 'https://x.test/api/v1');
    });
  });

  group('guard', () {
    test('an uncaught async error is logged with its stack', () async {
      start();
      await ZharpLogger.guard(() {
        Timer.run(() => throw StateError('boom'));
      }, exitOnError: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ZharpLogger.flushAll();
      final entry = backend.logs.single;
      expect(entry['level'], 'error');
      expect(entry['message'], 'Bad state: boom');
      expect((entry['metadata'] as Map)['type'], 'uncaughtError');
    });

    test('capturePrint sends prints inside guard, but not the SDK own lines', () async {
      start(capturePrint: true);
      await ZharpLogger.guard(() {
        print('hello from the app');
        print('[Zharp] not this one');
      }, exitOnError: false);
      await ZharpLogger.flushAll();
      expect(backend.logs.map((e) => e['message']), ['hello from the app']);
      expect((backend.logs.single['metadata'] as Map)['origin'], 'print');
    });

    test('without capturePrint, prints are not sent', () async {
      start();
      await ZharpLogger.guard(() => print('only on the console'), exitOnError: false);
      await ZharpLogger.flushAll();
      expect(backend.logs, isEmpty);
    });
  });

  test('toMessage', () {
    expect(toMessage(['a', 1]), '["a",1]');
    expect(toMessage(42), '42');
  });
}
