// A plain Dart server or tool: configured from its environment, its uncaught errors reported
// before it ends, and each error with the code that ran.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zharp_core/src/errors.dart' show sourceContextEnabled;
import 'package:zharp_core/src/source.dart';
import 'package:zharp_core/zharp_core.dart';

import 'fake_backend.dart';

/// Throws from a line the tests know.
double priceWithTax(double price) {
  if (price < 0) {
    throw ArgumentError.value(price, 'price', "can't be negative"); // the line that ran
  }
  return price * 1.2;
}

void main() {
  late FakeBackend backend;

  setUp(() {
    backend = FakeBackend();
    resetOutputCapture();
    sourceContextEnabled = true;
  });
  tearDown(() async => ZharpCore.instance?.close());

  ZharpCore start({bool captureSourceContext = true}) => ZharpCore.start(ZharpOptions(
        key: 'zpk_test',
        service: 'tool',
        endpoint: 'https://ingest.test/api/v1/otlp',
        httpClient: backend.client,
        captureSourceContext: captureSourceContext,
      ))!;

  Map<String, Object?> errorOf(Map<String, dynamic> record) => attrs(record['attributes'] as List);

  test('an error carries the code around its frames in the app, read where it runs', () async {
    final zharp = start();
    try {
      priceWithTax(-1);
    } catch (error, stack) {
      zharp.captureError(error, stackTrace: stack);
    }
    await zharp.flush();

    final error = errorOf(backend.logs.single);
    final code = jsonDecode(error['zharp.source_context'] as String) as List;
    final top = code.first as Map<String, dynamic>;
    expect(top['file'], endsWith('test/dart_program_test.dart'));
    expect(top['code'], contains('// the line that ran'));
    expect(top['pre'], hasLength(5));
    expect((top['pre'] as List).last, contains('if (price < 0)'));
    expect(top['post'], isNotEmpty);
    // The stack itself names the same place, so Zharp puts the code on that frame.
    expect(error['exception.stacktrace'], contains('${top['file']}:${top['line']}:'));
  });

  test('only the app: not the Dart SDK, pub packages or Zharp', () {
    final attributes = sourceContextAttributes([
      'StateError: x',
      '#0      List.first (dart:core-patch/growable_array.dart:344:5)',
      '#1      BaseClient.send (package:http/src/base_client.dart:50:3)',
      '#2      ZharpCore.startSpan (package:zharp_core/src/core.dart:315:47)',
      '#3      main (file:///nowhere/bin/missing.dart:3:3)',
    ].join('\n'));
    expect(attributes, isEmpty);
    final own = appPackages();
    expect(own, isNot(contains('http')));
    expect(own, isNot(contains('test')));
    expect(own, isNot(contains('zharp_core')));
  });

  test('captureSourceContext: false sends the error without its code', () async {
    final zharp = start(captureSourceContext: false);
    try {
      priceWithTax(-1);
    } catch (error, stack) {
      zharp.captureError(error, stackTrace: stack);
    }
    await zharp.flush();
    expect(errorOf(backend.logs.single), isNot(contains('zharp.source_context')));
  });

  test('ZharpCore.run: an uncaught error is reported as fatal and sent, then goes on as before', () async {
    final forwarded = Completer<Object>();
    runZonedGuarded(
      () => ZharpCore.run(() async {
        start();
        await Future<void>.delayed(Duration.zero);
        priceWithTax(-5);
      }),
      (error, _) => forwarded.complete(error),
    );
    final error = await forwarded.future.timeout(const Duration(seconds: 5));
    expect(error, isA<ArgumentError>());
    // Sent before the error went on (it would have ended the program).
    final record = backend.logs.single;
    expect(record['severityText'], 'FATAL');
    final attributes = errorOf(record);
    expect(attributes['exception.type'], 'ArgumentError');
    expect(attributes['zharp.handled'], 'false');
    expect(attributes['exception.stacktrace'], contains('priceWithTax'));
  });

  test('ZharpCore.run: an error escaping a span is sent on it, once, before the program would end', () async {
    final forwarded = Completer<Object>();
    runZonedGuarded(
      () => ZharpCore.run(() async {
        final zharp = start();
        await zharp.startSpan('import prices', (span) async {
          await Future<void>.delayed(Duration.zero);
          priceWithTax(-7);
        });
      }),
      (error, _) => forwarded.complete(error),
    );
    await forwarded.future.timeout(const Duration(seconds: 5));
    // Already in the exporter's hands when the error went on: nothing waits for a later flush.
    final span = backend.spans.single;
    expect(span['name'], 'import prices');
    final event = (span['events'] as List).single as Map<String, dynamic>;
    expect(attrs(event['attributes'] as List)['zharp.handled'], 'false');
    expect(backend.logs, isEmpty);
  });

  test("ZharpCore.run: an error a request already reported isn't sent twice", () async {
    final forwarded = Completer<Object>();
    runZonedGuarded(
      () => ZharpCore.run(() async {
        final zharp = start();
        final error = StateError('reported by the request');
        zharp.captureError(error, handled: false);
        throw error;
      }),
      (error, _) => forwarded.complete(error),
    );
    await forwarded.future.timeout(const Duration(seconds: 5));
    await ZharpCore.instance!.flush();
    expect(backend.logs, hasLength(1));
  });

  test('a server is configured from ZHARP_* in its environment', () async {
    final script = File('test/fixtures/env_config.dart').absolute.path;
    final result = await Process.run(Platform.resolvedExecutable, ['run', script], environment: {
      'ZHARP_KEY': 'zpk_from_env',
      'ZHARP_SERVICE': 'billing-worker',
      'ZHARP_ENVIRONMENT': 'staging',
      'ZHARP_RELEASE': 'billing@1.2.3',
      'ZHARP_ENDPOINT': 'https://ingest.test/custom/',
    });
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(jsonDecode((result.stdout as String).trim().split('\n').last), {
      'service.name': 'billing-worker',
      'deployment.environment.name': 'staging',
      'service.version': 'billing@1.2.3',
      'endpoint': 'https://ingest.test/custom',
    });
  });
}
