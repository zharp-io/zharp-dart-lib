/// Zharp for Dart servers on `dart:io`: [zharpHandler] traces an HttpServer's requests.
///
/// shelf (and so dart_frog) servers use `zharp_shelf`'s middleware instead.
library;

export 'src/http_server.dart' show zharpHandler;
export 'src/server.dart' show RequestScope, ServerRequest, setRequestRoute, startServerSpan;
