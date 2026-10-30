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
