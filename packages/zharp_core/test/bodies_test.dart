import 'dart:convert';

import 'package:test/test.dart';
import 'package:zharp_core/src/bodies.dart';
import 'package:zharp_core/zharp_core.dart' show redactUrl;

void main() {
  final errors = BodySettings(const CaptureBodies());
  final all = BodySettings(const CaptureBodies.all(maxSize: 1000, redactKeys: ['dateOfBirth']));

  group('settings', () {
    test('defaults to 32 KB, clamps to 128 KB, reads at least 64 KB raw', () {
      expect(errors.maxSize, 32 * 1024);
      expect(BodySettings(const CaptureBodies(maxSize: 1 << 20)).maxSize, 128 * 1024);
      expect(BodySettings(const CaptureBodies(maxSize: 0)).maxSize, 32 * 1024);
      expect(errors.rawLimit, 64 * 1024);
      expect(BodySettings(const CaptureBodies(maxSize: 100000)).rawLimit, 200000);
    });

    test('errors keeps failed requests and those without a response; all keeps every one', () {
      expect([200, 302, 399].map(errors.wanted), everyElement(isFalse));
      expect([400, 404, 500].map(errors.wanted), everyElement(isTrue));
      expect(errors.wanted(null), isTrue);
      expect(errors.wanted(0), isTrue);
      expect(all.wanted(200), isTrue);
    });

    test('urls narrows which requests are captured, written like tracingOrigins', () {
      final only = BodySettings(const CaptureBodies(urls: ['api.shop.test', '*.internal.test']));
      expect(only.allows(Uri.parse('https://api.shop.test/x')), isTrue);
      expect(only.allows(Uri.parse('https://a.internal.test/x')), isTrue);
      expect(only.allows(Uri.parse('https://cdn.other.test/x')), isFalse);
      expect(errors.allows(Uri.parse('https://anything.test/x')), isTrue);
    });
  });

  group('secret keys', () {
    test('built-in keys, ignoring case, - and _', () {
      for (final key in ['password', 'newPassword', 'API_KEY', 'x-api-key', 'accessToken', 'Authorization', 'card', 'cvv', 'card_number', 'ssn', 'session_id', 'otp', 'pin']) {
        expect(isSecretKey(key), isTrue, reason: key);
      }
      for (final key in ['email', 'name', 'cardholder', 'key', 'session', 'amount', 'pinned']) {
        expect(isSecretKey(key), isFalse, reason: key);
      }
    });

    test('redactKeys: a string ignoring case/-/_, a RegExp as is', () {
      expect(isSecretKey('date_of_birth', ['dateOfBirth']), isTrue);
      expect(isSecretKey('internalRef', [RegExp(r'^internal')]), isTrue);
      expect(isSecretKey('InternalRef', [RegExp(r'^internal')]), isFalse);
    });
  });

  group('formatBody', () {
    Map<String, dynamic> json(String side, Map<String, Object?> attributes) =>
        jsonDecode(attributes['http.$side.body'] as String) as Map<String, dynamic>;

    test('JSON: names kept, secret values filtered, redactKeys honoured, nested too', () {
      final a = bodyAttributes(
          'request',
          jsonEncode({
            'email': 'a@b.test',
            'password': 'hunter2',
            'dateOfBirth': '1990-01-01',
            'user': {'apiKey': 'k-1', 'name': 'Ada'},
            'empty': {'token': ''},
          }),
          'application/json',
          all);
      expect(json('request', a), {
        'email': 'a@b.test',
        'password': '[Filtered]',
        'dateOfBirth': '[Filtered]',
        'user': {'apiKey': '[Filtered]', 'name': 'Ada'},
        'empty': {'token': ''},
      });
      expect(a['http.request.header.content-type'], 'application/json');
    });

    test('a secret object keeps its keys, every value filtered', () {
      final a = bodyAttributes('request', jsonEncode({'card': {'brand': 'visa', 'last4': '4242', 'meta': {'n': 1}}}), 'application/json', errors);
      expect(json('request', a)['card'], {'brand': '[Filtered]', 'last4': '[Filtered]', 'meta': {'n': '[Filtered]'}});
    });

    test('form-urlencoded: secret values filtered, the rest as sent', () {
      final a = bodyAttributes('request', 'user=ada&password=p4ss&next=%2Fhome', 'application/x-www-form-urlencoded', errors);
      expect(a['http.request.body'], 'user=ada&password=[Filtered]&next=%2Fhome');
    });

    test('inline images and long base64 become a description; fields after them stay', () {
      final a = bodyAttributes(
          'request',
          jsonEncode({'avatar': 'data:image/png;base64,${'iVBORw0KGgo' * 4000}', 'blob': '${'QUJD' * 500}1', 'name': 'Ada'}),
          'application/json',
          errors);
      expect(json('request', a), {'avatar': '[image/png · 32 KB]', 'blob': '[base64 · 1 KB]', 'name': 'Ada'});
    });

    test('text that does not parse: secret pairs and base64 runs handled where they appear', () {
      final cutJson = '{"password":"hunter2","photo":"data:image/jpeg;base64,${'A1b2' * 200}';
      final a = bodyAttributes('request', cutJson, 'application/json', errors, cut: true);
      expect(a['http.request.body'], '{"password":"[Filtered]","photo":"[image/jpeg · 600 B+]"');
      expect(a['http.request.body.truncated'], isTrue);
    });

    test('long bodies are cut at maxSize and marked', () {
      final a = bodyAttributes('response', 'x' * 5000, 'text/plain', all);
      expect((a['http.response.body'] as String).length, 1000);
      expect(a['http.response.body.truncated'], isTrue);
      expect(bodyAttributes('response', 'short', 'text/plain', all).containsKey('http.response.body.truncated'), isFalse);
    });

    test('empty bodies and non-text types give nothing; multipart summaries are JSON', () {
      expect(bodyAttributes('request', '   ', 'application/json', errors), isEmpty);
      expect(bodyAttributes('request', 'abc', 'image/png', errors), isEmpty);
      final a = bodyAttributes('request', jsonEncode({'title': 'Hi', 'password': 'x', 'photo': fileLabel('me.png', 'image/png', 245760)}),
          'multipart/form-data', errors);
      expect(json('request', a), {'title': 'Hi', 'password': '[Filtered]', 'photo': '[file me.png · image/png · 240 KB]'});
      expect(a['http.request.header.content-type'], 'multipart/form-data');
    });
  });

  group('descriptions', () {
    test('sizes, files, binaries and event streams', () {
      expect(formatSize(900), '900 B');
      expect(formatSize(1536), '2 KB');
      expect(formatSize(1468006), '1.4 MB');
      expect(fileLabel(null, null, 10), '[file blob · 10 B]');
      expect(fileLabel('a.pdf', 'application/pdf', 2048, partial: true), '[file a.pdf · application/pdf · 2 KB+]');
      expect(describeBody('image/png; q=1', size: 3000), '[binary · image/png · 3 KB]');
      expect(describeBody(null), '[binary]');
      expect(describeBody('text/event-stream'), '[event stream]');
      expect(isTextual('text/event-stream'), isFalse);
      expect(isTextual('application/vnd.api+json'), isTrue);
      expect(isTextual(null), isTrue);
    });

    test('bytes: text decoded, binary and stray gzip described', () {
      expect(bytesAttributes('response', utf8.encode('{"ok":true}'), 'application/json', errors)['http.response.body'], '{"ok":true}');
      expect(bytesAttributes('response', [1, 2, 3], 'image/png', errors)['http.response.body'], '[binary · image/png · 3 B]');
      expect(bytesAttributes('response', [0x1f, 0x8b, 8, 0], 'application/json', errors, total: 4000)['http.response.body'],
          '[binary · application/json · 4 KB]');
      expect(bytesAttributes('response', const [], 'application/json', errors), isEmpty);
    });
  });

  group('URLs', () {
    test('secret query values filtered; key, sig, code and state too; the rest kept', () {
      expect(redactQuery('token=abc&page=2'), 'token=[Filtered]&page=2');
      expect(redactQuery('key=k&sig=s&code=c&state=x&user=ada&empty='), 'key=[Filtered]&sig=[Filtered]&code=[Filtered]&state=[Filtered]&user=ada&empty=');
      expect(redactUrl(Uri.parse('https://u:p@api.test:8443/a?access_token=t&q=1#frag')), 'https://api.test:8443/a?access_token=[Filtered]&q=1');
    });
  });
}
