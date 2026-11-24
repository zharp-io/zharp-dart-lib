/// What a Dart server or tool says about its own code with each error (dart:io): the lines
/// around its frames, read where it runs, and which packages are the app's.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

/// The SDK's own packages: never the app, never its code.
const Set<String> _sdkPackages = {'zharp_core', 'zharp_flutter', 'zharp_dio', 'zharp_shelf'};

/// Packages that come with the Flutter SDK rather than from pub.
final RegExp _flutterSdkPackage = RegExp(r'^(flutter|flutter_test|flutter_driver|flutter_localizations|flutter_web_plugins|integration_test|sky_engine|fuchsia_\w+)$');

/// A path inside the pub cache (hosted and git dependencies) or a Flutter install.
final RegExp _dependencyPath = RegExp(r'[\\/](\.pub-cache|Pub[\\/]Cache)[\\/]|[\\/]flutter[\\/](packages|bin[\\/]cache)[\\/]');

/// "#3      Cart.total (package:shop/cart.dart:12:5)" → location and line.
final RegExp _frame = RegExp(r'^\s*#\d+\s+.*\(([^()\s]+?):(\d+)(?::\d+)?\)\s*$');

const int _around = 5;
const int _maxFrames = 5;
const int _maxLine = 300;
const int _maxBytes = 12000;
const int _maxFile = 2000000;

/// `zharp.source_context`: for the app's innermost frames (at most five), the line that ran and
/// five either side, as `[{file, line, pre, code, post}]` with `file` exactly as the frame names
/// it. Only files that exist here: `dart run` has them; a compiled executable usually doesn't.
Map<String, Object> sourceContextAttributes(String stack) {
  try {
    final out = <Map<String, Object>>[];
    final seen = <String>{};
    for (final text in stack.split('\n')) {
      if (out.length >= _maxFrames) break;
      final match = _frame.firstMatch(text);
      if (match == null) continue;
      final location = match.group(1)!;
      final line = int.parse(match.group(2)!);
      if (line < 1 || !seen.add('$location:$line')) continue;
      final path = _appFile(location);
      if (path == null) continue;
      final lines = _lines(path);
      if (lines == null || line > lines.length) continue;
      out.add({
        'file': location,
        'line': line,
        'pre': [for (final l in lines.sublist(math.max(0, line - 1 - _around), line - 1)) _cut(l)],
        'code': _cut(lines[line - 1]),
        'post': [for (final l in lines.sublist(line, math.min(lines.length, line + _around))) _cut(l)],
      });
    }
    while (out.isNotEmpty) {
      final json = jsonEncode(out);
      if (utf8.encode(json).length <= _maxBytes) return {'zharp.source_context': json};
      out.removeLast();
    }
  } catch (_) {
    // Never into the app: the error goes without its code.
  }
  return const {};
}

/// `zharp.in_app`: the app's own packages — the root package and local path packages, not pub
/// dependencies, the Flutter SDK's or Zharp's — so Zharp tells `package:shop/…` frames from
/// `package:shelf/…` ones. From the program's package config; absent when there is none (a
/// compiled executable).
Map<String, Object> inAppAttributes() {
  final packages = appPackages();
  return packages == null || packages.isEmpty ? const {} : {'zharp.in_app': jsonEncode(packages.toList()..sort())};
}

Set<String>? _appPackages;
bool _appPackagesRead = false;

/// The app's own package names, from `.dart_tool/package_config.json`; null without one.
Set<String>? appPackages() {
  if (_appPackagesRead) return _appPackages;
  _appPackagesRead = true;
  try {
    final config = Isolate.packageConfigSync;
    if (config == null || config.scheme != 'file') return null;
    final json = jsonDecode(File.fromUri(config).readAsStringSync());
    final packages = json is Map ? json['packages'] : null;
    if (packages is! List) return null;
    final names = <String>{};
    for (final package in packages) {
      if (package is! Map) continue;
      final name = package['name'];
      final root = package['rootUri'];
      if (name is! String || root is! String) continue;
      if (_sdkPackages.contains(name) || _flutterSdkPackage.hasMatch(name)) continue;
      final rootUri = config.resolve(root.endsWith('/') ? root : '$root/');
      if (rootUri.scheme == 'file' && _dependencyPath.hasMatch(rootUri.toFilePath())) continue;
      names.add(name);
    }
    _appPackages = names;
  } catch (_) {
    _appPackages = null;
  }
  return _appPackages;
}

/// The file on disk behind a frame's location when it is the app's code; null otherwise.
String? _appFile(String location) {
  var uri = Uri.tryParse(location);
  if (uri == null) return null;
  if (uri.scheme == 'package') {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    if (_sdkPackages.contains(name) || _flutterSdkPackage.hasMatch(name)) return null;
    final own = appPackages();
    if (own != null && !own.contains(name)) return null;
    uri = Isolate.resolvePackageUriSync(uri);
    if (uri == null) return null;
  }
  if (uri.scheme != 'file') return null;
  final path = uri.toFilePath();
  return _dependencyPath.hasMatch(path) ? null : path;
}

final Map<String, List<String>?> _files = {};

List<String>? _lines(String path) {
  if (_files.containsKey(path)) return _files[path];
  if (_files.length > 50) _files.clear();
  List<String>? lines;
  try {
    final file = File(path);
    if (file.existsSync() && file.lengthSync() <= _maxFile) {
      lines = const LineSplitter().convert(file.readAsStringSync());
    }
  } catch (_) {
    lines = null;
  }
  return _files[path] = lines;
}

String _cut(String line) => line.length <= _maxLine ? line : '${line.substring(0, _maxLine - 1)}…';
