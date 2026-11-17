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
