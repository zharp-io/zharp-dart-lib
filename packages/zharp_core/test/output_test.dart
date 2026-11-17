import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:zharp_core/zharp_core.dart';

import 'fake_backend.dart';

/// A stdout/stderr that keeps what is written to it.
class _FakeStdout implements Stdout {
  final StringBuffer text = StringBuffer();

  @override
  void write(Object? object) => text.write(object);
  @override
  void writeln([Object? object = '']) => text.writeln(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => text.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => text.writeCharCode(charCode);
  @override
  void add(List<int> data) => text.write(utf8.decode(data));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeBackend backend;
  late List<String> printed;
  late _FakeStdout out;
  late _FakeStdout err;

  setUp(() {
    backend = FakeBackend();
    printed = [];
    out = _FakeStdout();
    err = _FakeStdout();
    resetOutputCapture();
  });
  tearDown(() async {
    await ZharpCore.instance?.close();
    Logger.root.clearListeners();
    Logger.root.level = Level.INFO;
    hierarchicalLoggingEnabled = false;
  });

  ZharpCore start({bool? logs = true, bool captureOutput = true, bool debug = false, bool? logCorrelation}) =>
      ZharpCore.start(ZharpOptions(
        key: 'zpk_test',
        service: 'api',
        endpoint: 'https://ingest.test/api/v1/otlp',
        httpClient: backend.client,
        logs: logs,
        captureOutput: captureOutput,
        logCorrelation: logCorrelation,
        debug: debug,
      ))!;

  /// Run [body] as an app would inside `ZharpCore.run`, with the terminal replaced by [printed],
  /// [out] and [err], so what the app prints can be checked.
  Future<void> app(FutureOr<void> Function() body) => runZoned(
        () => IOOverrides.runZoned(
          () => ZharpCore.run(() async => body()),
          stdout: () => out,
          stderr: () => err,
        ),
        zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)),
      );

  Future<List<Map<String, dynamic>>> sent(ZharpCore zharp) async {
    await Future<void>.delayed(Duration.zero);
    await zharp.flush();
    return backend.logs;
  }

  Map<String, Object?> attributesOf(Map<String, dynamic> log) => attrs(log['attributes'] as List);
  List<String> bodies(List<Map<String, dynamic>> logs) => [for (final log in logs) log['body']['stringValue'] as String];

  group('print', () {
    test('each print is sent, still printed, at the level the line says', () async {
      final zharp = start();
      await app(() {
        print('Server listening on :8080');
        print('ERROR could not reach the database');
        print('[warn] cache is cold');
        print('{"level":"error","msg":"payment failed","order":7}');
        print('SEVERE: 2026-11-17 db: connection lost');
        print('\u001b[31m[E] boom\u001b[0m');
      });
      final logs = await sent(zharp);
      expect(bodies(logs), [
        'Server listening on :8080',
        'ERROR could not reach the database',
        '[warn] cache is cold',
        'payment failed',
        'SEVERE: 2026-11-17 db: connection lost',
        '[E] boom',
      ]);
      expect([for (final log in logs) log['severityText']], ['INFO', 'ERROR', 'WARN', 'ERROR', 'ERROR', 'ERROR']);
      expect(attributesOf(logs.first), containsPair('log.source', 'print'));
      expect(attributesOf(logs.first)['session.id'], isNotNull);
      // The terminal shows exactly what was printed.
      expect(printed, hasLength(6));
      expect(printed.last, '\u001b[31m[E] boom\u001b[0m');
    });

    test('a print keeps the span it was written in', () async {
      final zharp = start();
      late ZharpSpan span;
      await app(() => zharp.startSpan('GET /orders', (s) async {
            span = s;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            print('loading orders');
          }));
      final log = (await sent(zharp)).single;
      expect(log['traceId'], span.traceId);
      expect(log['spanId'], span.spanId);
    });

    test("the logger package's box is one record at the emoji's level", () async {
      final zharp = start();
      await app(() {
        print('\u001b[38;5;196m┌──────────────────────\u001b[0m');
        print('\u001b[38;5;196m│ #0   main (file:///app/bin/server.dart:12:3)\u001b[0m');
        print('\u001b[38;5;196m├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\u001b[0m');
        print('\u001b[38;5;196m│ ⛔ Checkout failed\u001b[0m');
        print('\u001b[38;5;196m└──────────────────────\u001b[0m');
      });
      final log = (await sent(zharp)).single;
      expect(log['severityText'], 'ERROR');
      expect(log['body']['stringValue'], '#0   main (file:///app/bin/server.dart:12:3)\n⛔ Checkout failed');
    });

    test("the SDK's own lines are not sent", () async {
      final zharp = start(debug: true);
      await app(() => print('[Zharp] something about Zharp'));
      expect(await sent(zharp), isEmpty);
    });

    test('outside ZharpCore.run, print is not captured', () async {
      final zharp = start();
      runZoned(() => print('not in the zone'),
          zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)));
      expect(await sent(zharp), isEmpty);
    });
  });

  group('stdout and stderr', () {
    test('lines written to stdout and stderr are sent and still written', () async {
      final zharp = start();
      await app(() {
        stdout.writeln('GET /health 200 3ms');
        stdout.write('part one, ');
        stdout.write('part two\n');
        stderr.writeln('deprecated option --fast');
        stderr.add(utf8.encode('level=error msg="disk full"\n'));
        stdout.writeln('two\nlines');
      });
      final logs = await sent(zharp);
      expect(bodies(logs), [
        'GET /health 200 3ms',
        'part one, part two',
        'deprecated option --fast',
        'level=error msg="disk full"',
        'two',
        'lines',
      ]);
      expect([for (final log in logs) log['severityText']], ['INFO', 'INFO', 'WARN', 'ERROR', 'INFO', 'INFO']);
      expect(attributesOf(logs[2]), containsPair('log.iostream', 'stderr'));
      expect(out.text.toString(), 'GET /health 200 3ms\npart one, part two\ntwo\nlines\n');
      expect(err.text.toString(), 'deprecated option --fast\nlevel=error msg="disk full"\n');
    });

    test('an unfinished line is sent after a moment', () async {
      final zharp = start();
      await app(() => stdout.write('Downloading… 40%'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bodies(await sent(zharp)), ['Downloading… 40%']);
    });

    test('a line keeps the span it started in', () async {
      final zharp = start();
      late ZharpSpan span;
      await app(() => zharp.startSpan('job', (s) {
            span = s;
            stdout.writeln('step 1 done');
          }));
      final log = (await sent(zharp)).single;
      expect(log['spanId'], span.spanId);
    });
  });

  group('package:logging', () {
    test('records arrive with their own level and logger, in their span', () async {
      final zharp = start();
      hierarchicalLoggingEnabled = true;
      final db = Logger('app.db')..level = Level.ALL;
      late ZharpSpan span;
      zharp.startSpan('query', (s) {
        span = s;
        db.warning('slow query');
      });
      db.fine('connected');
      Logger('app').severe('failed to save', StateError('closed'), StackTrace.current);
      final logs = await sent(zharp);
      expect(bodies(logs), ['slow query', 'connected', 'failed to save']);
      expect([for (final log in logs) log['severityText']], ['WARN', 'DEBUG', 'ERROR']);
      expect(attributesOf(logs.first), containsPair('log.logger', 'app.db'));
      expect(attributesOf(logs.first), containsPair('log.source', 'logging'));
      expect(logs.first['spanId'], span.spanId);
      expect(attributesOf(logs.last), containsPair('exception.type', 'StateError'));
    });

    test('a record the app also prints is sent once', () async {
      // The usual setup: print every record. Listening before Zharp starts, so it prints before
      // Zharp sees the record.
      late ZharpCore zharp;
      await app(() {
        Logger.root.onRecord.listen((r) => print('${r.level.name}: ${r.loggerName}: ${r.message}'));
        zharp = start();
        Logger('orders').info('order 7 placed');
      });
      final logs = await sent(zharp);
      expect(bodies(logs), ['order 7 placed']);
      expect(attributesOf(logs.single), containsPair('log.source', 'logging'));
      expect(printed, ['INFO: orders: order 7 placed']);
    });
  });

  group('no duplicates', () {
    test('Zharp.log then printing the same text sends one record', () async {
      final zharp = start();
      await app(() {
        zharp.log.warn('Retrying payment');
        print('Retrying payment');
      });
      final logs = await sent(zharp);
      expect(bodies(logs), ['Retrying payment']);
      expect(logs.single['severityText'], 'WARN');
    });

    test('quietly() keeps a line out', () async {
      final zharp = start();
      await app(() => quietly(() => print('already sent')));
      expect(await sent(zharp), isEmpty);
      expect(printed, ['already sent']);
    });
  });

  group('captureOutput: false', () {
    test('nothing printed or logged through package:logging is sent; output unchanged', () async {
      final zharp = start(captureOutput: false);
      await app(() {
        print('hello');
        stdout.writeln('world');
        Logger('x').warning('nope');
      });
      expect(await sent(zharp), isEmpty);
      expect(printed, ['hello']);
      expect(out.text.toString(), 'world\n');
    });
  });

  group('logs off (the default)', () {
    test('nothing logged or printed is sent; errors and zharp.log still are', () async {
      final zharp = start(logs: null);
      expect(zharp.sendsLogs, isFalse);
      await app(() {
        print('hello');
        stdout.writeln('world');
        stderr.writeln('ERROR on stderr');
        Logger('x').severe('through logging');
        zharp.log.info('explicit log');
        zharp.captureError(StateError('broken'), stackTrace: StackTrace.current);
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final logs = await sent(zharp);
      expect(bodies(logs), ['explicit log', 'Bad state: broken']);
      expect(attributesOf(logs.last)['exception.type'], 'StateError');
      expect(printed, ['hello']);
      expect(out.text.toString(), 'world\n');
    });

    test('logs: false wins over nothing; true turns capture on', () {
      expect(start(logs: false).capturesOutput, isFalse);
      expect(start(logs: true).capturesOutput, isTrue);
      expect(start(logs: true, captureOutput: false).capturesOutput, isFalse);
    });
  });

  group('stamping (servers)', () {
    final pattern = RegExp(r'\s*\btrace_id=([0-9a-f]{32})\s+span_id=([0-9a-f]{16})\s*$', caseSensitive: false);

    test('a line printed in a span ends with its ids; outside a span it is unchanged', () async {
      final zharp = start(logs: null);
      late ZharpSpan span;
      await app(() async {
        print('before any request');
        await zharp.startSpan('GET /orders', (s) async {
          span = s;
          print('loading orders');
          stdout.writeln('rows: 3');
          stdout.write('partial ');
          stdout.write('line\n');
          stderr.writeln('slow query');
          stdout.add(utf8.encode('bytes line\n'));
          print('first\nsecond');
        });
        stdout.writeln('after the request');
      });
      final ids = 'trace_id=${span.traceId} span_id=${span.spanId}';
      expect(printed, ['before any request', 'loading orders $ids', 'first $ids\nsecond $ids']);
      expect(out.text.toString(),
          'rows: 3 $ids\npartial line $ids\nbytes line $ids\nafter the request\n');
      expect(err.text.toString(), 'slow query $ids\n');
      final match = pattern.firstMatch(printed[1])!;
      expect(match.group(1), span.traceId);
      expect(match.group(2), span.spanId);
      expect(span.traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      // Logs are off: nothing printed was sent.
      expect(await sent(zharp), isEmpty);
    });

    test('a JSON line gets trace_id and span_id fields and stays valid JSON', () async {
      final zharp = start(logs: null);
      late ZharpSpan span;
      await app(() => zharp.startSpan('job', (s) {
            span = s;
            stdout.writeln('{"level":"info","msg":"done","n":2}');
            print('{}');
          }));
      final record = jsonDecode(out.text.toString().trim()) as Map<String, dynamic>;
      expect(record, {'level': 'info', 'msg': 'done', 'n': 2, 'trace_id': span.traceId, 'span_id': span.spanId});
      expect(jsonDecode(printed.single), {'trace_id': span.traceId, 'span_id': span.spanId});
    });

    test('lines with a trace_id already, and the SDK\'s own, are left alone', () {
      const t = '0af7651916cd43dd8448eb211c80319c';
      const s = 'b7ad6b7169203331';
      expect(stampLine('x trace_id=abc', t, s), 'x trace_id=abc');
      expect(stampLine('[Zharp] started', t, s), '[Zharp] started');
      expect(stampLine('', t, s), '');
      expect(stampLine('done\r', t, s), 'done trace_id=$t span_id=$s\r');
      expect(stampLine('tail of a record}', t, s), 'tail of a record}');
    });

    test('logs on: the line is sent without the stamp and printed with it', () async {
      final zharp = start();
      late ZharpSpan span;
      await app(() => zharp.startSpan('job', (s) {
            span = s;
            print('working');
          }));
      final log = (await sent(zharp)).single;
      expect(log['body']['stringValue'], 'working');
      expect(log['spanId'], span.spanId);
      expect(printed.single, 'working trace_id=${span.traceId} span_id=${span.spanId}');
    });

    test('logCorrelation: false prints every line unchanged', () async {
      final zharp = start(logs: null, logCorrelation: false);
      await app(() => zharp.startSpan('job', (s) {
            print('working');
            stdout.writeln('more');
          }));
      expect(printed, ['working']);
      expect(out.text.toString(), 'more\n');
    });

    test('switchOn: option, then environment / define, then the default', () {
      expect(switchOn(true, 'ZHARP_NOT_SET', 'false', fallback: false), isTrue);
      expect(switchOn(null, 'ZHARP_NOT_SET', 'yes', fallback: false), isTrue);
      expect(switchOn(null, 'ZHARP_NOT_SET', 'off', fallback: true), isFalse);
      expect(switchOn(null, 'ZHARP_NOT_SET', '', fallback: true), isTrue);
    });
  });

  group('parseLine', () {
    Severity? level(String line) => parseLine(line).severity;

    test('levels', () {
      expect(level('plain text'), isNull);
      expect(level('2026-11-17T10:00:00Z ERROR db: timeout'), Severity.error);
      expect(level('level=warn msg=slow'), Severity.warn);
      expect(level('[debug] cache miss'), Severity.debug);
      expect(level('WARNING: 2026-11-17: app: low memory'), Severity.warn);
      expect(level('FINE: connected'), Severity.debug);
      expect(level('Everything is fine, really'), isNull);
      expect(level('{"level":50,"msg":"x"}'), Severity.error);
      expect(level('{"severity":"WARNING","message":"x"}'), Severity.warn);
      expect(level('💡 Ready'), Severity.info);
      expect(level('[W] careful'), Severity.warn);
      expect(level('[FATAL] dead'), Severity.fatal);
    });

    test('a JSON line sends its message', () {
      expect(parseLine('{"level":"info","msg":"started"}').body, 'started');
      expect(parseLine('{"not":"a log"}').body, '{"not":"a log"}');
      expect(parseLine('\u001b[32mgreen\u001b[0m').body, 'green');
    });
  });
}
