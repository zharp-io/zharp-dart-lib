import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// [bytes] gzipped, or null where gzip isn't available.
List<int>? gzipBytes(List<int> bytes) {
  try {
    return gzip.encode(bytes);
  } catch (_) {
    return null;
  }
}

/// The client the exporter makes for itself. Idle connections close after a few seconds, so a
/// finished Dart program isn't kept alive by one.
http.Client createHttpClient() => IOClient(HttpClient()..idleTimeout = const Duration(seconds: 3));

/// `os.name` / `os.version` as dart:io reports them. Flutter replaces these with what the device
/// says (dart:io gives the kernel version on Android).
Map<String, Object> platformAttributes() {
  final attributes = <String, Object>{};
  try {
    attributes['os.name'] = switch (Platform.operatingSystem) {
      'ios' => 'iOS',
      'android' => 'Android',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      'fuchsia' => 'Fuchsia',
      final other => other,
    };
    attributes['os.version'] = Platform.operatingSystemVersion;
  } catch (_) {
    // A sandbox that won't say.
  }
  return attributes;
}

/// The process environment, for configuration in pure-Dart programs.
String? environmentValue(String name) {
  final value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Run [body] with `stdout` and `stderr` replaced by ones that hand each write to [capture] and
/// then write it exactly as before.
R runWithCapturedStdio<R>(R Function() body, void Function(String chunk, {required bool isError}) capture) {
  final Stdout out;
  final Stdout err;
  try {
    out = _CapturedStdout(stdout, (chunk) => capture(chunk, isError: false));
    err = _CapturedStdout(stderr, (chunk) => capture(chunk, isError: true));
  } catch (_) {
    return body();
  }
  return IOOverrides.runZoned(body, stdout: () => out, stderr: () => err);
}

/// A `Stdout` that copies what is written to [_take] and passes every call to [_inner].
class _CapturedStdout implements Stdout {
  _CapturedStdout(this._inner, this._take);

  final Stdout _inner;
  final void Function(String chunk) _take;

  late final ByteConversionSink _bytes =
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(_ChunkSink(_copy));

  void _copy(String chunk) {
    try {
      _take(chunk);
    } catch (_) {}
  }

  void _copyBytes(List<int> data) {
    try {
      _bytes.add(data);
    } catch (_) {}
  }

  @override
  void write(Object? object) {
    final text = '$object';
    _copy(text);
    _inner.write(text);
  }

  @override
  void writeln([Object? object = '']) {
    final text = '$object';
    _copy('$text\n');
    _inner.writeln(text);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final text = objects.join(separator);
    _copy(text);
    _inner.write(text);
  }

  @override
  void writeCharCode(int charCode) {
    _copy(String.fromCharCode(charCode));
    _inner.writeCharCode(charCode);
  }

  @override
  void add(List<int> data) {
    _copyBytes(data);
    _inner.add(data);
  }

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) => _inner.addStream(stream.map((data) {
        _copyBytes(data);
        return data;
      }));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);

  @override
  Future<dynamic> flush() => _inner.flush();

  @override
  Future<dynamic> close() => _inner.close();

  @override
  Future<dynamic> get done => _inner.done;

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding encoding) => _inner.encoding = encoding;

  @override
  String get lineTerminator => _inner.lineTerminator;

  @override
  set lineTerminator(String lineTerminator) => _inner.lineTerminator = lineTerminator;

  @override
  bool get hasTerminal => _inner.hasTerminal;

  @override
  int get terminalColumns => _inner.terminalColumns;

  @override
  int get terminalLines => _inner.terminalLines;

  @override
  bool get supportsAnsiEscapes => _inner.supportsAnsiEscapes;

  /// Writes through it are not copied.
  @override
  IOSink get nonBlocking => _inner.nonBlocking;

  /// Members a later SDK adds to `Stdout` still compile; they are not forwarded.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ChunkSink extends StringConversionSinkBase {
  _ChunkSink(this._onChunk);
  final void Function(String chunk) _onChunk;

  @override
  void addSlice(String chunk, int start, int end, bool isLast) {
    if (end > start) _onChunk(chunk.substring(start, end));
  }

  @override
  void close() {}
}
