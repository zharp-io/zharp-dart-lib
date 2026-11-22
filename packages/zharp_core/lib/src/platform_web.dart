import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:http/http.dart' as http;

/// Browsers can't be asked to gzip a request body synchronously; it goes uncompressed.
List<int>? gzipBytes(List<int> bytes) => null;

http.Client createHttpClient() => http.Client();

Map<String, Object> platformAttributes() => const {'os.name': 'web'};

String? environmentValue(String name) => null;

/// No stdout or stderr on the web: [body] just runs.
R runWithCapturedStdio<R>(
  R Function() body,
  void Function(String chunk, {required bool isError}) capture,
  String Function(String chunk) stamp,
) =>
    body();

/// No agent reads a browser's console: lines are never stamped.
const bool canStampOutput = false;

/// `zharp.debug_ids` for an error's stack: which build each `.js` file in it came from, so Zharp
/// can find the uploaded source map and show Dart frames. `zharp sourcemaps inject` (the same
/// CLI as for any JS build) adds a line to `main.dart.js` that registers its debug ID in
/// `globalThis.__zharpDebugIds`, keyed by a stack taken inside the file; its top frame names the
/// file as this browser sees it. Empty when the build wasn't injected.
Map<String, Object> debugIdAttributes(String stack) {
  try {
    final registry = globalContext['__zharpDebugIds'];
    final entries = registry?.dartify();
    if (entries is! Map) return const {};
    final files = <String, String>{};
    entries.forEach((key, id) {
      if (key is! String || id is! String) return;
      for (final line in key.split('\n')) {
        final file = _frameFile(line);
        if (file != null) {
          files[file] = id;
          break;
        }
      }
    });
    if (files.isEmpty) return const {};
    final ids = <String, String>{};
    for (final line in stack.split('\n')) {
      final file = _frameFile(line);
      final id = file == null ? null : files[file];
      if (id != null) ids[file!] = id;
    }
    return ids.isEmpty ? const {} : {'zharp.debug_ids': jsonEncode(ids)};
  } catch (_) {
    return const {};
  }
}

final RegExp _v8Frame = RegExp(r'^at (?:async )?(?:.*? \()?(.+?):\d+:\d+\)?$');
final RegExp _geckoFrame = RegExp(r'^(?:[^@]*@)?(.+?):\d+:\d+$');

/// The file a JS stack line points at: V8 (`at fn (file:1:2)`) or Gecko/WebKit (`fn@file:1:2`).
String? _frameFile(String line) {
  final text = line.trim();
  if (text.isEmpty) return null;
  final v8 = _v8Frame.firstMatch(text);
  final file = v8 != null ? v8.group(1) : (text.startsWith('at ') ? null : _geckoFrame.firstMatch(text)?.group(1));
  if (file == null || file.isEmpty || file.contains('eval at ') || file == '<anonymous>' || file == 'native') return null;
  return file;
}
