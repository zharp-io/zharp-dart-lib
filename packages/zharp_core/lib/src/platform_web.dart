import 'package:http/http.dart' as http;

/// Browsers can't be asked to gzip a request body synchronously; it goes uncompressed.
List<int>? gzipBytes(List<int> bytes) => null;

http.Client createHttpClient() => http.Client();

Map<String, Object> platformAttributes() => const {'os.name': 'web'};

String? environmentValue(String name) => null;
