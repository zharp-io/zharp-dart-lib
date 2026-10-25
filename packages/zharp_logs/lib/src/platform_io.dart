import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An environment variable of the running process; null when unset or blank.
String? processEnv(String name) {
  final value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// What is known about where the app runs. Captured once; it doesn't change while it runs.
Map<String, Object?> runtimeContext() {
  String? hostname;
  try {
    hostname = processEnv('HOSTNAME') ?? Platform.localHostname;
  } catch (_) {
    // Some sandboxes refuse to say.
  }
  return {
    if (hostname != null) 'hostname': hostname,
    'pid': '$pid',
    // "3.5.0 (stable) (…) on "linux_x64"" — the version is the first word.
    'dartVersion': Platform.version.split(' ').first,
    'platform': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
  };
}

/// The app's own name, from the pubspec.yaml above the script that was started — the name a
/// service gets when none is configured. Null when there's none to read (a compiled executable
/// deployed on its own, a Flutter app).
String? pubspecName() {
  try {
    var dir = File.fromUri(Platform.script).parent;
    for (var i = 0; i < 8; i++) {
      final pubspec = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
      if (pubspec.existsSync()) {
        final match = RegExp(r'^name:\s*([A-Za-z0-9_]+)\s*$', multiLine: true).firstMatch(pubspec.readAsStringSync());
        if (match != null) return match.group(1);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  } catch (_) {
    // Not run from a file (a snapshot, a test runner) or not readable: no name.
  }
  return null;
}

/// The client the logger makes for itself. Idle connections are dropped after a second: the
/// default keeps one open for 15 s, which keeps a finished script running that long.
http.Client createHttpClient() => IOClient(HttpClient()..idleTimeout = const Duration(seconds: 1));

/// Whether a crash can end the process the way an unhandled error would have.
const bool canExitProcess = true;

/// Print the error as Dart would, and end the process with a failure code.
Never exitWithError(Object error, StackTrace stack) {
  stderr.writeln('Unhandled exception:\n$error\n$stack');
  exit(1);
}
