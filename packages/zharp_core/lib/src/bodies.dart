/// Request and response bodies on HTTP CLIENT spans (`captureBodies`), and secrets in URLs.
///
/// The same rules as every other Zharp SDK, so a payload reads the same in a trace whichever
/// app sent it:
/// - field names stay; values under keys that look secret (`password`, `token`, `authorization`,
///   `card`, …) become `[Filtered]`, plus any keys the app adds — under a secret object, every
///   value inside is filtered and its keys kept
/// - an inline image or other long base64 value becomes `[image/png · 24 KB]`, a file in a form
///   upload `[file photo.png · image/png · 240 KB]`, and a body that is not text a one-line
///   description (`[binary · application/pdf · 1.2 MB]`, `[event stream]`)
/// - text is capped (32 KB by default), with `http.*.body.truncated` set when it was cut
library;

import 'dart:convert';

import 'propagation.dart';

/// Which requests keep their bodies.
enum BodyMode {
  /// Only requests that failed: status 400 and above, or no response at all.
  errors,

  /// Every request.
  all,
}

/// `captureBodies`: request and response bodies on HTTP CLIENT spans. Off unless set.
///
/// ```dart
/// ZharpOptions(key: 'zpk_…', captureBodies: const CaptureBodies())        // failed requests
/// ZharpOptions(key: 'zpk_…', captureBodies: const CaptureBodies.all())    // every request
/// ```
class CaptureBodies {
  const CaptureBodies({this.mode = BodyMode.errors, this.maxSize = defaultMaxBody, this.redactKeys = const [], this.urls});

  /// Every request, not only failed ones.
  const CaptureBodies.all({this.maxSize = defaultMaxBody, this.redactKeys = const [], this.urls}) : mode = BodyMode.all;

  final BodyMode mode;

  /// Characters kept per body. Default 32768 (32 KB), at most 131072 (128 KB).
  final int maxSize;

  /// More keys whose values are replaced with `[Filtered]`, on top of the built-in ones. A
  /// [String] matches a key ignoring case, `-` and `_` (`accountNumber` also covers
  /// `account_number`); a [RegExp] is tested against the key as it is.
  final List<Pattern> redactKeys;

  /// Which requests have their bodies captured, written like `tracingOrigins` (a host,
  /// `*.example.com`, an origin, or a [RegExp]). Default: every request the app makes — never
  /// Zharp's own.
  final List<Pattern>? urls;
}

const int defaultMaxBody = 32 * 1024;
const int maxBody = 128 * 1024;
const String filtered = '[Filtered]';

/// [CaptureBodies] as used: the size clamped.
class BodySettings {
  BodySettings(CaptureBodies options)
      : mode = options.mode,
        maxSize = options.maxSize > 0 ? (options.maxSize > maxBody ? maxBody : options.maxSize) : defaultMaxBody,
        extraKeys = options.redactKeys,
        urls = options.urls;

  final BodyMode mode;
  final int maxSize;
  final List<Pattern> extraKeys;
  final List<Pattern>? urls;

  /// Raw text read before shortening and capping: inline images shrink to a few words, so more
  /// is read than is kept.
  int get rawLimit => maxSize * 2 > 64 * 1024 ? maxSize * 2 : 64 * 1024;

  /// Whether a request with this outcome keeps its bodies. Null or 0 means no response.
  bool wanted(int? status) => mode == BodyMode.all || status == null || status == 0 || status >= 400;

  /// Whether requests to [url] may have their bodies captured.
  bool allows(Uri url) => urls == null || shouldPropagate(url, urls!);
}

const Map<String, String> bodyAttributeNames = {
  'request': 'http.request.body',
  'requestTruncated': 'http.request.body.truncated',
  'requestType': 'http.request.header.content-type',
  'response': 'http.response.body',
  'responseTruncated': 'http.response.body.truncated',
  'responseType': 'http.response.header.content-type',
};

// ── content types ─────────────────────────────────────────────────────────────

String _mime(String? contentType) => (contentType ?? '').split(';').first.trim().toLowerCase();

bool isEventStream(String? contentType) => _mime(contentType) == 'text/event-stream';

bool isMultipart(String? contentType) => _mime(contentType) == 'multipart/form-data';

final RegExp _textualApplication =
    RegExp(r'^application\/(json|xml|x-www-form-urlencoded|graphql|javascript|x-ndjson|ld\+json)$');

/// Whether a body of this type is text worth showing. An unknown type is given the benefit of the doubt.
bool isTextual(String? contentType) {
  final type = _mime(contentType);
  if (type.isEmpty) return true;
  if (type == 'text/event-stream') return false;
  return type.startsWith('text/') || type.endsWith('+json') || type.endsWith('+xml') || _textualApplication.hasMatch(type);
}

bool _isForm(String? contentType) => _mime(contentType) == 'application/x-www-form-urlencoded';

/// `240 KB`, `1.4 MB`.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// How a file in a form upload is shown: `[file photo.png · image/png · 240 KB]`.
String fileLabel(String? name, String? type, int? size, {bool partial = false}) {
  final parts = ['file ${name == null || name.isEmpty ? 'blob' : name}'];
  if (type != null && type.isNotEmpty) parts.add(type);
  if (size != null) parts.add(formatSize(size) + (partial ? '+' : ''));
  return '[${parts.join(' · ')}]';
}

/// What a body that is not text says instead: `[binary · image/png · 24 KB]`, `[event stream]`.
String describeBody(String? contentType, {int? size, bool partial = false}) {
  if (isEventStream(contentType)) return '[event stream]';
  final parts = ['binary'];
  final type = _mime(contentType);
  if (type.isNotEmpty) parts.add(type);
  if (size != null && size > 0) parts.add(formatSize(size) + (partial ? '+' : ''));
  return '[${parts.join(' · ')}]';
}

// ── redaction ─────────────────────────────────────────────────────────────────

/// Built-in keys whose values never leave the app, compared without case, `-` or `_`.
const List<String> _contains = [
  'password', 'passwd', 'passphrase', 'secret', 'token', 'apikey', 'accesskey', 'privatekey', //
  'authorization', 'cookie', 'creditcard', 'cardnumber', 'cvv', 'cvc', 'ssn', 'iban', 'sessionid',
  'signature', 'credential',
];
const List<String> _exact = ['auth', 'pin', 'pwd', 'otp', 'card', 'pan', 'jwt', 'sid', 'codeverifier'];

/// Also secret in a query string, where they are API keys and signed-URL signatures.
const List<String> _urlExact = ['key', 'sig', 'code', 'state', 'session'];

final RegExp _notAlnum = RegExp(r'[^a-z0-9]');
String _normalize(String key) => key.toLowerCase().replaceAll(_notAlnum, '');

bool isSecretKey(String key, [List<Pattern> extra = const []]) {
  final k = _normalize(key);
  if (k.isEmpty) return false;
  if (_exact.contains(k) || _contains.any(k.contains)) return true;
  return extra.any((p) => p is RegExp ? p.hasMatch(key) : _normalize(p.toString()) == k);
}

final RegExp _dataUri = RegExp(r'^data:([\w.+-]+\/[\w.+-]+)?(?:;[\w=.+-]+)*;base64,([A-Za-z0-9+/=\s]*)$');
final RegExp _base64 = RegExp(r'^[A-Za-z0-9+/_-]{256,}={0,2}$');
final RegExp _base64Hint = RegExp(r'[0-9+/]');

/// A long base64 value as a short description; other strings as they are.
String _shorten(String value) {
  if (value.length < 256) return value;
  final uri = _dataUri.firstMatch(value);
  if (uri != null) return '[${uri.group(1) ?? 'data'} · ${formatSize((uri.group(2)!.length * 3) ~/ 4)}]';
  if (_base64.hasMatch(value) && _base64Hint.hasMatch(value)) return '[base64 · ${formatSize((value.length * 3) ~/ 4)}]';
  return value;
}

/// Every value under [value] filtered, its keys kept.
Object? _filterAll(Object? value, int depth) {
  if (depth > 20) return filtered;
  if (value == null || value == '') return value;
  if (value is List) return [for (final v in value) _filterAll(v, depth + 1)];
  if (value is Map) return {for (final e in value.entries) '${e.key}': _filterAll(e.value, depth + 1)};
  return filtered;
}

/// [value] with secrets filtered and long base64 shortened; keys always kept.
Object? redactValue(Object? value, List<Pattern> extra, [int depth = 0]) {
  if (value is String) return _shorten(value);
  if (depth > 20 || value == null) return value;
  if (value is List) return [for (final v in value) redactValue(v, extra, depth + 1)];
  if (value is Map) {
    return {
      for (final e in value.entries)
        '${e.key}': isSecretKey('${e.key}', extra) ? _filterAll(e.value, depth + 1) : redactValue(e.value, extra, depth + 1),
    };
  }
  return value;
}

final RegExp _looseRuns = RegExp(r'"((?:data:[\w.+-]+\/[\w.+-]+(?:;[\w=.+-]+)*;base64,)?[A-Za-z0-9+/_=-]{256,})("?)');
final RegExp _loosePairs = RegExp(r'("([^"\\]{1,100})"\s*:\s*)("(?:[^"\\]|\\.)*"?|-?\d[\d.eE+-]*|true|false)');

/// Text that did not parse (cut-off JSON, a body that only looks like JSON): `"key": value`
/// pairs under secret keys are filtered where they appear, and long base64 runs shortened.
String _redactLoose(String text, List<Pattern> extra) {
  final runs = text.replaceAllMapped(_looseRuns, (m) {
    final run = m.group(1)!;
    final short = _shorten(run);
    if (short == run) return m.group(0)!;
    return m.group(2)!.isNotEmpty ? '"$short"' : '"${short.substring(0, short.length - 1)}+]"';
  });
  return runs.replaceAllMapped(_loosePairs, (m) => isSecretKey(m.group(2)!, extra) ? '${m.group(1)}"$filtered"' : m.group(0)!);
}

String _decodeComponent(String s) {
  try {
    return Uri.decodeQueryComponent(s);
  } catch (_) {
    return s;
  }
}

String _redactForm(String text, List<Pattern> extra) => text.split('&').map((pair) {
      final eq = pair.indexOf('=');
      if (eq < 0) return pair;
      final rawKey = pair.substring(0, eq);
      if (isSecretKey(_decodeComponent(rawKey), extra)) return '$rawKey=$filtered';
      final value = pair.substring(eq + 1);
      if (value.length < 256) return pair;
      final decoded = _decodeComponent(value);
      final short = _shorten(decoded);
      return short == decoded ? pair : '$rawKey=$short';
    }).join('&');

// ── the attribute value ───────────────────────────────────────────────────────

/// A body as it is sent: redacted, then cut to `maxSize`. [cut] says the text was already cut
/// short where it was read. Null for an empty body. A `multipart/form-data` body is passed as
/// the JSON of its fields (files already described).
({String value, bool truncated})? formatBody(String? text, String? contentType, BodySettings settings, {bool cut = false}) {
  if (text == null || text.trim().isEmpty) return null;
  var body = text;
  if (_isForm(contentType)) {
    body = _redactForm(body, settings.extraKeys);
  } else {
    final trimmed = body.trim();
    Object? parsed;
    var ok = false;
    if (!cut && (trimmed.startsWith('{') || trimmed.startsWith('['))) {
      try {
        parsed = jsonDecode(trimmed);
        ok = true;
      } catch (_) {}
    }
    body = ok ? jsonEncode(redactValue(parsed, settings.extraKeys)) : _redactLoose(body, settings.extraKeys);
  }
  final truncated = cut || body.length > settings.maxSize;
  return (value: body.length > settings.maxSize ? body.substring(0, settings.maxSize) : body, truncated: truncated);
}

/// The span attributes for one side of a request (`request` or `response`).
Map<String, Object?> bodyAttributes(String side, String? text, String? contentType, BodySettings settings, {bool cut = false}) {
  if (!isTextual(contentType) && !isMultipart(contentType)) return const {};
  final formatted = formatBody(text, contentType, settings, cut: cut);
  if (formatted == null) return const {};
  return {
    bodyAttributeNames[side]!: formatted.value,
    if (formatted.truncated) bodyAttributeNames['${side}Truncated']!: true,
    if (contentType != null && contentType.isNotEmpty) bodyAttributeNames['${side}Type']!: contentType,
  };
}

/// The attributes for a body that is not text: what it was, not what it said.
Map<String, Object?> describedAttributes(String side, String? contentType, {int? size, bool partial = false}) => {
      bodyAttributeNames[side]!: describeBody(contentType, size: size, partial: partial),
      if (contentType != null && contentType.isNotEmpty) bodyAttributeNames['${side}Type']!: contentType,
    };

/// The attributes for bytes: text kept (decoded as UTF-8), anything else described. [cut] says
/// more bytes followed; [total] is the full size when known.
Map<String, Object?> bytesAttributes(String side, List<int> bytes, String? contentType, BodySettings settings,
    {bool cut = false, int? total}) {
  if (bytes.isEmpty && total == null) return const {};
  // A compressed body nobody inflated: not text, whatever its type says.
  final gzipped = bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  if (gzipped || !isTextual(contentType)) {
    return describedAttributes(side, contentType, size: total ?? bytes.length, partial: total == null && cut);
  }
  var text = utf8.decode(bytes, allowMalformed: true);
  // A multi-byte character split at the cap decodes as U+FFFD; drop it.
  if (cut && text.endsWith('\uFFFD')) text = text.substring(0, text.length - 1);
  return bodyAttributes(side, text, contentType, settings, cut: cut);
}

// ── URLs ──────────────────────────────────────────────────────────────────────

/// A query string (without `?`) with secret-looking values filtered.
String redactQuery(String query, [List<Pattern> extra = const []]) {
  if (query.isEmpty) return query;
  return query.split('&').map((pair) {
    final eq = pair.indexOf('=');
    if (eq < 0) return pair;
    final key = _decodeComponent(pair.substring(0, eq));
    final secret = isSecretKey(key, extra) || _urlExact.contains(_normalize(key));
    return secret && eq < pair.length - 1 ? '${pair.substring(0, eq)}=$filtered' : pair;
  }).join('&');
}
