import 'package:http/http.dart' as http;

http.Client createHttpClient() => http.Client();

/// A web page has no process environment; configuration comes from code or `--dart-define`.
String? processEnv(String name) => null;

Map<String, Object?> runtimeContext() => {'platform': 'web'};

String? pubspecName() => null;

/// A page can't be ended; an uncaught error is logged and left to the browser.
const bool canExitProcess = false;

Never exitWithError(Object error, StackTrace stack) => throw UnsupportedError('No process to exit on the web');
