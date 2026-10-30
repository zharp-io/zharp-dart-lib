import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:zharp_core/src/exporter.dart';
import 'package:zharp_core/src/otlp.dart';

import 'fake_backend.dart';

LogData _log(int i) => LogData(timeMicros: 1000 + i, severity: Severity.info, body: 'log $i', attributes: {'i': i});

void main() {
  late FakeBackend backend;
  late List<String> warnings;

  setUp(() {
    backend = FakeBackend();
    warnings = [];
  });

  Exporter exporter(FakeAsync async, {int maxBatchSize = 100, int maxQueueSize = 1000, int maxRequestBytes = 1000000}) {
    final start = DateTime.utc(2026, 1, 1);
    return Exporter(
      key: 'zpk_test',
      endpoint: 'https://ingest.test/api/v1/otlp',
      client: backend.client,
      resource: {'service.name': 'shop', 'telemetry.sdk.language': 'dart'},
      maxBatchSize: maxBatchSize,
      maxQueueSize: maxQueueSize,
      maxRequestBytes: maxRequestBytes,
      warn: warnings.add,
      clock: () => start.add(async.elapsed),
    );
  }

  test('batches on the interval, gzipped, with the key as a bearer token', () {
    fakeAsync((async) {
      final e = exporter(async);
      e.addLog(_log(1));
      e.addLog(_log(2));
      async.elapse(const Duration(seconds: 4));
      expect(backend.requests, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(backend.requests, hasLength(1));
      final request = backend.requests.single;
      expect(request.url.toString(), 'https://ingest.test/api/v1/otlp/v1/logs');
      expect(request.headers['Authorization'], 'Bearer zpk_test');
      expect(request.headers['Content-Encoding'], 'gzip');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(backend.resourceOf(request)['telemetry.sdk.language'], 'dart');
      expect(backend.logs.map((l) => l['body']['stringValue']), ['log 1', 'log 2']);
    });
  });

  test('sends at once when a batch is full, and splits by size', () {
    fakeAsync((async) {
      final e = exporter(async, maxBatchSize: 3);
      for (var i = 0; i < 7; i++) {
        e.addLog(_log(i));
      }
      // Without waiting for the interval: everything queued goes, three per request.
      async.flushMicrotasks();
      expect(backend.requests.length, 3);
      expect(backend.logs, hasLength(7));

      backend.requests.clear();
      final small = exporter(async, maxRequestBytes: 400);
      for (var i = 0; i < 4; i++) {
        small.addLog(_log(i));
      }
      async.elapse(const Duration(seconds: 6));
      expect(backend.requests.length, greaterThan(1));
      expect(backend.logs, hasLength(4));
    });
  });

  test('offline: keeps records, backs off, and sends them once back', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.offline = true;
      e.addLog(_log(1));
      async.elapse(const Duration(seconds: 6));
      expect(e.pending, 1);
      // Backoff grows: nothing for a while even with more records arriving.
      e.addLog(_log(2));
      async.elapse(const Duration(seconds: 30));
      expect(e.pending, 2);
      backend.offline = false;
      async.elapse(const Duration(minutes: 6));
      expect(backend.logs.map((l) => l['body']['stringValue']), ['log 1', 'log 2']);
      expect(e.pending, 0);
    });
  });

  test('the buffer is capped: the oldest records go first', () {
    fakeAsync((async) {
      final e = exporter(async, maxQueueSize: 5);
      backend.offline = true;
      for (var i = 0; i < 8; i++) {
        e.addLog(_log(i));
      }
      expect(e.pending, 5);
      expect(e.dropped, 3);
      backend.offline = false;
      unawaited(e.flush());
      async.flushMicrotasks();
      expect(backend.logs.map((l) => l['body']['stringValue']), ['log 3', 'log 4', 'log 5', 'log 6', 'log 7']);
    });
  });

  test('429 and 503 are retried, honouring Retry-After', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.status = 429;
      backend.responseHeaders = {'retry-after': '20'};
      e.addLog(_log(1));
      async.elapse(const Duration(seconds: 6));
      expect(backend.requests, hasLength(1));
      backend.status = 200;
      backend.responseHeaders = const {};
      async.elapse(const Duration(seconds: 18));
      expect(backend.requests, hasLength(1));
      async.elapse(const Duration(seconds: 2));
      expect(backend.requests, hasLength(2));
      expect(e.pending, 0);
    });
  });

  test('400 drops the batch without retrying', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.status = 400;
      e.addLog(_log(1));
      async.elapse(const Duration(minutes: 10));
      expect(backend.requests, hasLength(1));
      expect(e.pending, 0);
    });
  });

  test('401 warns once and stops sending until the key is retried', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.status = 401;
      e.addLog(_log(1));
      async.elapse(const Duration(seconds: 6));
      e.addLog(_log(2));
      async.elapse(const Duration(seconds: 6));
      expect(backend.requests, hasLength(1));
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('HTTP 401'));
      expect(e.pending, 0);
      // An hour later one batch is tried; accepted, sending resumes.
      backend.status = 200;
      async.elapse(const Duration(hours: 1));
      e.addLog(_log(3));
      async.elapse(const Duration(seconds: 6));
      expect(backend.requests, hasLength(2));
      expect(warnings.last, contains('accepted'));
    });
  });

  test('flush sends now, even during a backoff wait', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.status = 503;
      e.addLog(_log(1));
      async.elapse(const Duration(milliseconds: 5100));
      expect(backend.requests, hasLength(1));
      backend.status = 200;
      var done = false;
      e.flush().then((_) => done = true);
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(backend.requests, hasLength(2));
      expect(e.pending, 0);
    });
  });

  test('a server error that keeps happening drops the batch after five tries', () {
    fakeAsync((async) {
      final e = exporter(async);
      backend.status = 500;
      e.addLog(_log(1));
      async.elapse(const Duration(hours: 1));
      expect(backend.requests, hasLength(5));
      expect(e.pending, 0);
    });
  });
}
