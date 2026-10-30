import 'package:test/test.dart';
import 'package:zharp_core/src/errors.dart';
import 'package:zharp_core/src/ids.dart';
import 'package:zharp_core/src/otlp.dart';
import 'package:zharp_core/src/propagation.dart';
import 'package:zharp_core/src/session.dart';

void main() {
  group('ids', () {
    test('trace and span IDs are W3C hex of the right length', () {
      for (var i = 0; i < 100; i++) {
        expect(isValidTraceId(newTraceId()), isTrue);
        expect(isValidSpanId(newSpanId()), isTrue);
      }
      expect(newUuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });
  });

  group('otlp', () {
    test('values map to AnyValue; int64 and timestamps are decimal strings', () {
      expect(anyValue('a'), {'stringValue': 'a'});
      expect(anyValue(3), {'intValue': '3'});
      expect(anyValue(1.5), {'doubleValue': 1.5});
      expect(anyValue(true), {'boolValue': true});
      expect(anyValue([1, 'x']), {
        'arrayValue': {
          'values': [
            {'intValue': '1'},
            {'stringValue': 'x'},
          ],
        },
      });
      expect(nanosString(1700000000123456), '1700000000123456000');
    });

    test('sanitize drops nulls, keeps JSON-able values, turns the rest into text', () {
      final clean = sanitizeAttributes({
        'a': null,
        'b': 1,
        'c': DateTime.utc(2026, 1, 2),
        'd': const Duration(seconds: 2),
        'e': Uri.parse('https://x.test'),
        'f': double.nan,
        'g': {'h': null, 'i': 2},
      });
      expect(clean, {
        'b': 1,
        'c': '2026-01-02T00:00:00.000Z',
        'd': 2000,
        'e': 'https://x.test',
        'f': 'NaN',
        'g': {'i': 2},
      });
    });

    test('a span encodes as an OTLP span', () {
      final span = SpanData(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        parentSpanId: null,
        name: 'screen /home',
        kind: SpanKind.internal,
        startMicros: 1000,
        endMicros: 2000,
        attributes: {'k': 'v'},
        events: [
          SpanEventData('exception', 1500, {'exception.type': 'StateError'})
        ],
        statusCode: SpanStatusCode.error,
        statusMessage: 'boom',
      ).toOtlp();
      expect(span['traceId'], 'a' * 32);
      expect(span.containsKey('parentSpanId'), isFalse);
      expect(span['kind'], 1);
      expect(span['startTimeUnixNano'], '1000000');
      expect(span['endTimeUnixNano'], '2000000');
      expect(span['status'], {'code': 2, 'message': 'boom'});
      expect((span['events'] as List).single, {
        'name': 'exception',
        'timeUnixNano': '1500000',
        'attributes': [
          {
            'key': 'exception.type',
            'value': {'stringValue': 'StateError'},
          },
        ],
      });
    });
  });

  group('propagation', () {
    test('traceparent round-trips', () {
      final header = formatTraceparent('a' * 32, 'b' * 16, sampled: true);
      expect(header, '00-${'a' * 32}-${'b' * 16}-01');
      final parsed = parseTraceparent(header)!;
      expect(parsed.traceId, 'a' * 32);
      expect(parsed.sampled, isTrue);
      expect(parseTraceparent('00-${'0' * 32}-${'b' * 16}-01'), isNull);
      expect(parseTraceparent('garbage'), isNull);
    });

    test('baggage is percent-encoded, empty values left out, and merges', () {
      expect(formatBaggage({'enduser.id': 'a b@c', 'session.id': null}), 'enduser.id=a%20b%40c');
      expect(parseBaggage('enduser.id=a%20b;prop=1, other=x'), {'enduser.id': 'a b', 'other': 'x'});
      expect(mergeBaggage('other=x,enduser.id=old', {'enduser.id': 'new'}), 'other=x,enduser.id=new');
    });

    test('tracingOrigins: hosts, wildcards, origins and regexps; nothing by default', () {
      final api = Uri.parse('https://api.example.com/orders');
      expect(shouldPropagate(api, []), isFalse);
      expect(shouldPropagate(api, ['api.example.com']), isTrue);
      expect(shouldPropagate(api, ['example.com']), isFalse);
      expect(shouldPropagate(api, ['*.example.com']), isTrue);
      expect(shouldPropagate(Uri.parse('https://example.com/'), ['*.example.com']), isFalse);
      expect(shouldPropagate(api, ['https://api.example.com']), isTrue);
      expect(shouldPropagate(api, ['http://api.example.com']), isFalse);
      expect(shouldPropagate(Uri.parse('http://localhost:8080/x'), ['localhost:8080']), isTrue);
      expect(shouldPropagate(Uri.parse('http://localhost:9090/x'), ['localhost:8080']), isFalse);
      expect(shouldPropagate(api, [RegExp(r'^https://api\.')]), isTrue);
      expect(shouldPropagate(Uri.parse('https://evil.test/?api.example.com'), ['api.example.com']), isFalse);
    });
  });

  group('session', () {
    late DateTime now;
    late SessionManager session;
    setUp(() {
      now = DateTime.utc(2026, 1, 1);
      session = SessionManager(clock: () => now);
    });

    test('stays the same while active', () {
      final id = session.touch();
      now = now.add(const Duration(minutes: 29));
      expect(session.touch(), id);
      now = now.add(const Duration(minutes: 29));
      expect(session.touch(), id);
    });

    test('a new one after 30 minutes in the background, not after a short trip', () {
      final id = session.touch();
      session.background();
      now = now.add(const Duration(minutes: 5));
      session.foreground();
      expect(session.touch(), id);
      session.background();
      now = now.add(const Duration(minutes: 30));
      session.foreground();
      expect(session.touch(), isNot(id));
    });

    test('a new one after 30 idle minutes, and on reset', () {
      final id = session.touch();
      now = now.add(const Duration(minutes: 31));
      final second = session.touch();
      expect(second, isNot(id));
      session.reset();
      expect(session.id, isNot(second));
    });

    test('records made in the background don\'t expire the session', () {
      final id = session.touch();
      session.background();
      now = now.add(const Duration(minutes: 40));
      expect(session.touch(), id);
    });
  });

  group('errors', () {
    test('Type: message first, then the Dart frames', () {
      try {
        throw StateError('cart is empty');
      } catch (error, stack) {
        final d = describeError(error, stack);
        expect(d.type, 'StateError');
        expect(d.message, 'Bad state: cart is empty');
        final lines = d.stacktrace.split('\n');
        expect(lines.first, 'StateError: Bad state: cart is empty');
        expect(lines[1], startsWith('#0'));
        expect(d.attributes(handled: true)['zharp.handled'], 'true');
      }
    });

    test('Exception(x) reads as Exception: x', () {
      final d = describeError(Exception('nope'), null);
      expect(d.type, 'Exception');
      expect(d.message, 'nope');
      expect(d.stacktrace.split('\n').first, 'Exception: nope');
      // No stack given: where it was described, without SDK frames.
      expect(d.stacktrace, contains('units_test.dart'));
      expect(d.stacktrace, isNot(contains('package:zharp_core/')));
    });

    test('a message that repeats the type is not doubled', () {
      final d = describeError(const FormatException('bad json'), null);
      expect(d.message, 'bad json');
      expect(d.stacktrace.split('\n').first, 'FormatException: bad json');
    });

    test('an Error keeps the stack it was thrown with', () {
      late Error caught;
      try {
        throw ArgumentError('x');
      } on Error catch (e) {
        caught = e;
      }
      expect(describeError(caught, null).stacktrace, contains('units_test.dart'));
    });

    test('reported errors are remembered; strings never are', () {
      final error = StateError('x');
      expect(wasReported(error), isFalse);
      markReported(error);
      expect(wasReported(error), isTrue);
      markReported('text');
      expect(wasReported('text'), isFalse);
    });
  });
}
