/// Everything the app prints, as logs (with `ZharpOptions.logs` on), and the request ids stamped on
/// printed lines (servers, `ZharpOptions.logCorrelation`).
///
/// Dart code logs in many ways: `print`, Flutter's `debugPrint`, `package:logging`, the `logger`
/// package (which prints), `stdout.writeln`, and libraries doing any of these. The captures here
/// send each line once, tied to the trace, span and session it was written in, and leave what is
/// printed exactly as it was:
///
/// - **Exact**: `package:logging` records (with their own level and logger name), Flutter's
///   `debugPrint` (zharp_flutter) and `Zharp.log` itself.
/// - **Catch-all**: `print` and writes to `stdout`/`stderr` made inside [runCapturingOutput]
///   (`ZharpCore.run`, `Zharp.guard`). A line's level is read from the line — a JSON record's
///   `level`, a level word such as `ERROR`, `[warn]`, `level=error` or `SEVERE`, the `logger`
///   package's `[E]` prefix or emoji — else info (`print`, `stdout`) or a warning (`stderr`).
///
/// A line an exact capture already sent is not sent again when it then reaches the output: the
/// catch-all waits a microtask before sending, and skips a line containing a body sent in the
/// last few seconds.
library;

import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart' as logging;

import 'core.dart';
import 'errors.dart';
import 'otlp.dart';
import 'platform.dart';
import 'span.dart';

/// Lines longer than this are cut.
const int maxLineLength = 32 * 1024;

/// An unfinished line (no newline yet) is sent after this long.
const Duration lineFlushDelay = Duration(milliseconds: 200);

// ─── Quiet: the SDK printing what it already sent ────────────────────────────

int _quietDepth = 0;

/// Run [body] with the catch-all standing aside — for printing a line an exact capture has
/// already sent, and for the SDK's own work.
T quietly<T>(T Function() body) {
  _quietDepth++;
  try {
    return body();
  } finally {
    _quietDepth--;
  }
}

bool get _isQuiet => _quietDepth > 0;

// ─── Recently sent bodies ────────────────────────────────────────────────────

const Duration _recentWindow = Duration(seconds: 3);
const int _recentMax = 500;
final Stopwatch _monotonic = Stopwatch()..start();

class _Sent {
  _Sent(this.at, this.text, this.lines);
  final Duration at;
  final String text;

  /// A multi-line body's lines, which may reach the output one by one (`debugPrint` splits).
  final Set<String>? lines;
}

final List<_Sent> _recent = [];
final RegExp _spaces = RegExp(r'\s+');
String _normalise(String text) => text.replaceAll(_spaces, ' ').trim();

/// Remember a body an exact capture sent, so the same text printed a moment later isn't sent again.
void rememberSent(String body) {
  try {
    final text = _normalise(body);
    if (text.length < 4) return;
    final lines = body.contains('\n')
        ? {for (final line in body.split('\n')) if (_normalise(line).length >= 4) _normalise(line)}
        : null;
    _recent.add(_Sent(_monotonic.elapsed, text, lines));
    if (_recent.length > _recentMax) _recent.removeRange(0, _recent.length - _recentMax);
  } catch (_) {}
}

/// Whether a printed [line] is one already sent: it contains a recent body, or is one line of a
/// recent multi-line body.
bool alreadySent(String line) {
  final now = _monotonic.elapsed;
  _recent.removeWhere((sent) => now - sent.at > _recentWindow);
  if (_recent.isEmpty) return false;
  final text = _normalise(line);
  if (text.isEmpty) return false;
  for (var i = _recent.length - 1; i >= 0; i--) {
    final sent = _recent[i];
    if (text.contains(sent.text)) {
      _recent.removeAt(i);
      return true;
    }
    if (sent.lines != null && sent.lines!.contains(text)) return true;
  }
  return false;
}

/// For tests: forget what was sent.
void resetOutputCapture() {
  _recent.clear();
  _queue.clear();
  _drainScheduled = false;
  for (final stream in _streams.values) {
    stream._reset();
  }
}

// ─── Reading a line ──────────────────────────────────────────────────────────

/// A printed line, read for its level and, for formats worth knowing, its own message.
class ParsedLine {
  const ParsedLine(this.severity, this.body, [this.attributes = const {}]);

  /// Null when the line doesn't say.
  final Severity? severity;
  final String body;
  final Map<String, Object> attributes;
}

const Map<String, Severity> _levels = {
  'trace': Severity.trace,
  'verbose': Severity.debug,
  'debug': Severity.debug,
  'log': Severity.info,
  'info': Severity.info,
  'notice': Severity.info,
  'warn': Severity.warn,
  'warning': Severity.warn,
  'error': Severity.error,
  'err': Severity.error,
  'crit': Severity.fatal,
  'critical': Severity.fatal,
  'fatal': Severity.fatal,
  'emerg': Severity.fatal,
  'alert': Severity.fatal,
  // package:logging's level names.
  'finest': Severity.trace,
  'finer': Severity.trace,
  'fine': Severity.debug,
  'config': Severity.info,
  'severe': Severity.error,
  'shout': Severity.fatal,
};

final RegExp _ansi = RegExp('\u001b\\[[0-9;?]*[ -/]*[@-~]');

/// The first generic level word near the start of a line: `ERROR`, `[warn]`, `level=error`.
final RegExp _word = RegExp(
  r'(?:^|[\s\[(|:=])(trace|verbose|debug|info|notice|warn(?:ing)?|err(?:or)?|crit(?:ical)?|fatal|emerg|alert)(?=$|[\s\]):|,])',
  caseSensitive: false,
);

/// package:logging's names, in capitals only (`fine` is an ordinary word): `SEVERE: …`.
final RegExp _loggingWord = RegExp(r'(?:^|[\s\[(|:=])(FINEST|FINER|FINE|CONFIG|SEVERE|SHOUT)(?=$|[\s\]):|,])');

/// The `logger` package's SimplePrinter: `[E] message`.
final RegExp _loggerPrefix = RegExp(r'^\s*\[(T|D|I|W|E|FATAL)\]\s');
const Map<String, Severity> _loggerPrefixes = {
  'T': Severity.trace,
  'D': Severity.debug,
  'I': Severity.info,
  'W': Severity.warn,
  'E': Severity.error,
  'FATAL': Severity.fatal,
};

/// The `logger` package's PrettyPrinter emoji.
const Map<String, Severity> _emoji = {
  '🐛': Severity.debug,
  '💡': Severity.info,
  '⚠️': Severity.warn,
  '⛔': Severity.error,
  '👾': Severity.fatal,
};

Severity? _levelOf(Object? value) {
  if (value is num) {
    // pino and bunyan write their level as a number.
    if (value >= 60) return Severity.fatal;
    if (value >= 50) return Severity.error;
    if (value >= 40) return Severity.warn;
    if (value >= 30) return Severity.info;
    if (value >= 20) return Severity.debug;
    return Severity.trace;
  }
  return value is String ? _levels[value.toLowerCase()] : null;
}

/// Colour codes taken out of [text].
String stripAnsi(String text) => text.contains('\u001b') ? text.replaceAll(_ansi, '') : text;

/// Read a printed line.
ParsedLine parseLine(String raw) {
  final line = stripAnsi(raw).trimRight();
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
    try {
      final record = jsonDecode(trimmed);
      if (record is Map) {
        final message = record['msg'] ?? record['message'] ?? record['event'];
        return ParsedLine(
          _levelOf(record['level'] ?? record['severity'] ?? record['lvl']),
          message is String ? message : line,
        );
      }
    } catch (_) {
      // Not JSON after all; read it as text.
    }
  }
  final prefix = _loggerPrefix.firstMatch(line);
  if (prefix != null) return ParsedLine(_loggerPrefixes[prefix.group(1)], line);
  final head = line.length > 120 ? line.substring(0, 120) : line;
  for (final entry in _emoji.entries) {
    if (head.contains(entry.key)) return ParsedLine(entry.value, line);
  }
  final word = _word.firstMatch(head);
  final loggingWord = _loggingWord.firstMatch(head);
  final first = word == null
      ? loggingWord
      : loggingWord == null
          ? word
          : (loggingWord.start < word.start ? loggingWord : word);
  return ParsedLine(first == null ? null : _levels[first.group(1)!.toLowerCase()], line);
}

// ─── The catch-all ───────────────────────────────────────────────────────────

class _Entry {
  _Entry(this.text, this.source, this.fallback, this.span, this.remember, Zone? zone) : zone = zone ?? Zone.current;
  final String text;

  /// Where it was written: the request it belongs to.
  final Zone zone;
  final String source;
  final Severity fallback;
  final ZharpSpan? span;

  /// Sent by an exact capture that also prints it (debugPrint): remembered once sent.
  final bool remember;
}

final List<_Entry> _queue = [];
bool _drainScheduled = false;

void _enqueue(_Entry entry) {
  _queue.add(entry);
  if (_drainScheduled) return;
  _drainScheduled = true;
  // A microtask later, so an exact capture of the same line (a package:logging listener that
  // prints before Zharp's own listener runs) has been remembered first. In the root zone, so
  // no zone of the app's (or a test's fake clock) holds it.
  Zone.root.scheduleMicrotask(_drain);
}

void _drain() {
  _drainScheduled = false;
  final entries = List.of(_queue);
  _queue.clear();
  for (final entry in entries) {
    try {
      _send(entry);
    } catch (_) {
      // Never into the app.
    }
  }
}

void _send(_Entry entry) {
  final core = ZharpCore.instance;
  if (core == null || !core.capturesOutput) return;
  var text = entry.text.length > maxLineLength ? entry.text.substring(0, maxLineLength) : entry.text;
  if (text.trim().isEmpty || text.contains('[Zharp]')) return;
  // Flutter's short form of an error it has already dumped (and Zharp already reported).
  if (text.startsWith('Another exception was thrown:')) return;
  if (alreadySent(text)) return;
  final parsed = parseLine(text);
  text = parsed.body;
  if (text.trim().isEmpty) return;
  quietly(() => core.log.emitCaptured(
        parsed.severity ?? entry.fallback,
        text,
        {
          'log.source': entry.source,
          if (entry.source == 'stdout' || entry.source == 'stderr') 'log.iostream': entry.source,
          ...parsed.attributes,
        },
        span: entry.span,
        zone: entry.zone,
      ));
  if (entry.remember) rememberSent(text);
}

ZharpSpan? _spanIn(Zone? zone) {
  final value = zone?[spanZoneKey];
  if (value is ZharpSpan) return value;
  return ZharpCore.instance?.tracer.ambient?.span.isEnded == false ? ZharpCore.instance!.tracer.ambient!.span : null;
}

/// Lines from one source, joined back into records: an unfinished line waits for its newline
/// (at most [lineFlushDelay]); the `logger` package's boxes (`┌── … └──`) become one record.
class _Stream {
  _Stream(this.source, this.fallback);

  final String source;
  final Severity fallback;

  String _pending = '';
  ZharpSpan? _pendingSpan;
  Zone? _pendingZone;
  Timer? _lineTimer;

  List<String>? _box;
  ZharpSpan? _boxSpan;
  Zone? _boxZone;
  Timer? _boxTimer;

  void _reset() {
    _lineTimer?.cancel();
    _boxTimer?.cancel();
    _pending = '';
    _box = null;
  }

  /// A chunk written to a stream: lines end at newlines.
  void write(String chunk, ZharpSpan? span) {
    if (chunk.isEmpty) return;
    // A line belongs to the span it started in.
    if (_pending.isEmpty) {
      _pendingSpan = span;
      _pendingZone = Zone.current;
    }
    _pending += chunk;
    if (!_pending.contains('\n')) {
      if (_pending.length > maxLineLength) {
        _flushPending();
      } else {
        _lineTimer ??= Zone.root.createTimer(lineFlushDelay, _flushPending);
      }
      return;
    }
    final lines = _pending.split('\n');
    _pending = lines.removeLast();
    final lineSpan = _pendingSpan;
    final lineZone = _pendingZone;
    if (_pending.isNotEmpty) {
      _pendingSpan = span;
      _pendingZone = Zone.current;
    }
    for (final line in lines) {
      this.line(line.endsWith('\r') ? line.substring(0, line.length - 1) : line, lineSpan, zone: lineZone);
    }
    _lineTimer?.cancel();
    _lineTimer = _pending.isEmpty ? null : Zone.root.createTimer(lineFlushDelay, _flushPending);
  }

  void _flushPending() {
    _lineTimer?.cancel();
    _lineTimer = null;
    final text = _pending;
    _pending = '';
    if (text.isNotEmpty) line(text, _pendingSpan, zone: _pendingZone);
  }

  /// A whole line (or a whole `print`), written in [zone].
  void line(String text, ZharpSpan? span, {bool remember = false, Zone? zone}) {
    final plain = stripAnsi(text);
    final head = plain.trimLeft();
    if (_box != null) {
      if (head.startsWith('└')) {
        _endBox();
        return;
      }
      if (head.startsWith('│')) {
        _box!.add(head.substring(1).trimLeft());
        _armBox();
        return;
      }
      if (head.startsWith('├')) {
        _armBox();
        return;
      }
      _endBox();
    }
    if (head.startsWith('┌') && !head.contains('\n')) {
      _box = [];
      _boxSpan = span;
      _boxZone = zone ?? Zone.current;
      _armBox();
      return;
    }
    _enqueue(_Entry(plain, source, fallback, span, remember, zone));
  }

  void _armBox() {
    _boxTimer?.cancel();
    _boxTimer = Zone.root.createTimer(lineFlushDelay, _endBox);
  }

  void _endBox() {
    _boxTimer?.cancel();
    _boxTimer = null;
    final box = _box;
    _box = null;
    if (box != null && box.isNotEmpty) _enqueue(_Entry(box.join('\n'), source, fallback, _boxSpan, false, _boxZone));
  }

  /// Send what is waiting now.
  void flush() {
    if (_pending.isNotEmpty) _flushPending();
    if (_box != null) _endBox();
  }
}

final Map<String, _Stream> _streams = {};

_Stream _stream(String source, Severity fallback) => _streams[source] ??= _Stream(source, fallback);

/// Whether a capture should run now: Zharp started with output capture on, and not quiet.
bool get _capturing => !_isQuiet && (ZharpCore.instance?.capturesOutput ?? false);

/// A message printed whole (`print`, `debugPrint`) in [zone]. [remember]: the source prints it
/// later too (debugPrint's throttling), so once sent it is remembered.
void captureMessage(String? message, {required String source, Zone? zone, bool remember = false}) {
  try {
    if (message == null || !_capturing) return;
    _stream(source, Severity.info).line(message, _spanIn(zone ?? Zone.current), remember: remember, zone: zone);
  } catch (_) {}
}

/// A chunk written to `stdout` or `stderr`.
void captureChunk(String chunk, {required bool isError}) {
  try {
    if (!_capturing) return;
    _stream(isError ? 'stderr' : 'stdout', isError ? Severity.warn : Severity.info)
        .write(chunk, _spanIn(Zone.current));
  } catch (_) {}
}

/// Send unfinished lines now (before the SDK flushes or closes).
void flushCapturedOutput() {
  try {
    for (final stream in _streams.values) {
      stream.flush();
    }
    if (_queue.isNotEmpty) _drain();
  } catch (_) {}
}

final Object _captureZoneKey = Object();

/// Run [body] where `print` and writes to `stdout`/`stderr` (dart:io) are sent as logs too, each
/// still printed as before. Nested calls add nothing.
R runCapturingOutput<R>(R Function() body) {
  if (Zone.current[_captureZoneKey] == true) return body();
  return runZoned(
    () => runWithCapturedStdio(body, captureChunk, stampChunk),
    zoneValues: {_captureZoneKey: true},
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {
      // Sent as written; printed with the request's ids.
      captureMessage(line, source: 'print', zone: zone);
      var out = line;
      try {
        out = _stampText('$line\n', zone);
        out = out.substring(0, out.length - 1);
      } catch (_) {
        out = line;
      }
      parent.print(zone, out);
    }),
  );
}

// ─── Stamping: the request's ids on each printed line ───────────────────────

final RegExp _zeroIds = RegExp(r'^0+$');

/// [chunk] with every complete line in it (ending in a newline) stamped with the ids of the span
/// current in [zone] — when stamping is on and a span is active; otherwise [chunk] itself.
String _stampText(String chunk, Zone? zone) {
  final core = ZharpCore.instance;
  if (core == null || !core.stampsLines || _isQuiet || !chunk.contains('\n')) return chunk;
  final value = (zone ?? Zone.current)[spanZoneKey];
  final span = value is ZharpSpan ? value : core.tracer.ambient?.span;
  if (span == null || span.isEnded || _zeroIds.hasMatch(span.traceId)) return chunk;
  final parts = chunk.split('\n');
  var changed = false;
  for (var i = 0; i < parts.length - 1; i++) {
    final next = stampLine(parts[i], span.traceId, span.spanId);
    if (!identical(next, parts[i])) {
      parts[i] = next;
      changed = true;
    }
  }
  return changed ? parts.join('\n') : chunk;
}

/// A chunk written to `stdout`/`stderr`, stamped (see [stampLine]) when a span is active.
String stampChunk(String chunk) {
  try {
    return _stampText(chunk, Zone.current);
  } catch (_) {
    // An unstamped line is better than a lost one.
    return chunk;
  }
}

/// [line] ending with ` trace_id=<traceId> span_id=<spanId>`; a JSON record gets the two as
/// fields instead. Blank lines, lines already carrying a trace_id and the SDK's own are returned
/// as they are.
String stampLine(String line, String traceId, String spanId) {
  final cr = line.endsWith('\r') ? '\r' : '';
  final body = cr.isEmpty ? line : line.substring(0, line.length - 1);
  final trimmed = body.trimRight();
  if (trimmed.trim().isEmpty || body.contains('trace_id') || body.contains('[Zharp]')) return line;
  final traceHex = traceId.toLowerCase();
  final spanHex = spanId.toLowerCase();
  final rest = body.substring(trimmed.length);
  if (trimmed.endsWith('}')) {
    // A JSON record gets fields; the tail of a record written in pieces is left as it is.
    if (!trimmed.trimLeft().startsWith('{')) return line;
    final close = trimmed.lastIndexOf('}');
    final inner = trimmed.substring(trimmed.indexOf('{') + 1, close).trim();
    final fields = '"trace_id":"$traceHex","span_id":"$spanHex"';
    return '${trimmed.substring(0, close)}${inner.isEmpty ? '' : ','}$fields}$rest$cr';
  }
  return '$trimmed trace_id=$traceHex span_id=$spanHex$rest$cr';
}

/// An on/off setting: [option] when given, else the environment variable [name], else the
/// `--dart-define` value [defined], else [fallback]. `true`/`1`/`yes`/`on` and
/// `false`/`0`/`no`/`off`.
bool switchOn(bool? option, String name, String defined, {required bool fallback}) {
  if (option != null) return option;
  for (final candidate in [_environment(name), defined]) {
    final value = candidate?.trim().toLowerCase() ?? '';
    if (const ['true', '1', 'yes', 'on'].contains(value)) return true;
    if (const ['false', '0', 'no', 'off'].contains(value)) return false;
  }
  return fallback;
}

String? _environment(String name) {
  try {
    return environmentValue(name);
  } catch (_) {
    return null;
  }
}

// ─── package:logging ────────────────────────────────────────────────────────

/// Send every `package:logging` record (at the level the app lets through) with its own level,
/// logger name and, for SEVERE and above, its error. Returns the undo.
void Function() captureLoggingRecords() {
  final subscription = logging.Logger.root.onRecord.listen((record) {
    try {
      final core = ZharpCore.instance;
      if (core == null || !core.capturesOutput) return;
      final value = record.level.value;
      final severity = value >= logging.Level.SHOUT.value
          ? Severity.fatal
          : value >= logging.Level.SEVERE.value
              ? Severity.error
              : value >= logging.Level.WARNING.value
                  ? Severity.warn
                  : value >= logging.Level.CONFIG.value
                      ? Severity.info
                      : value >= logging.Level.FINE.value
                          ? Severity.debug
                          : Severity.trace;
      final error = record.error;
      final attributes = <String, Object?>{
        'log.source': 'logging',
        if (record.loggerName.isNotEmpty) 'log.logger': record.loggerName,
      };
      var body = record.message;
      if (error != null) {
        final autogenerated = error is String && error.startsWith('autogenerated stack trace');
        if (!autogenerated && severity.number >= Severity.error.number) {
          // Filed as an error, with its stack.
          attributes.addAll(describeError(error, record.stackTrace).attributes(handled: true));
        } else if (!autogenerated) {
          attributes['exception.message'] = '$error';
        }
      }
      if (body.isEmpty && error != null) body = '$error';
      quietly(() => core.log.emitCaptured(severity, body, attributes, span: _spanIn(record.zone), zone: record.zone));
      rememberSent(body);
    } catch (_) {}
  });
  return () => unawaited(subscription.cancel());
}

/// `ZHARP_CAPTURE_OUTPUT=false` (environment, or `--dart-define`) turns output capture off.
bool outputCaptureAllowed() {
  String? value;
  try {
    value = environmentValue('ZHARP_CAPTURE_OUTPUT');
  } catch (_) {}
  value ??= const String.fromEnvironment('ZHARP_CAPTURE_OUTPUT');
  final setting = value.trim().toLowerCase();
  return setting != 'false' && setting != '0' && setting != 'off';
}
