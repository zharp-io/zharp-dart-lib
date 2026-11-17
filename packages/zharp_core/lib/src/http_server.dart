import 'dart:async';
import 'dart:io';

import 'output.dart';
import 'server.dart';

/// `dart:io`'s HttpServer, traced: wrap the handler you pass to `listen`.
///
/// ```dart
/// final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
/// server.listen(zharpHandler((request) async {
///   request.response.write('ok');
///   await request.response.close();
/// }));
/// ```
///
/// Each request gets a SERVER span `METHOD path` that continues the caller's trace
/// (`traceparent`, `baggage`) and ends when the response is done, with its status — an error for
/// 5xx. The handler runs with that span current, so `zharp.log`, `startSpan`, traced outgoing
/// requests and `setUser` belong to the request, and every line it prints ends with the request's
/// `trace_id` and `span_id` (see `ZharpOptions.logCorrelation`). An error the handler throws is
/// reported and marks the span, then goes where it went before. Before Zharp starts, the handler
/// runs untouched.
void Function(HttpRequest request) zharpHandler(FutureOr<void> Function(HttpRequest request) handler) {
  return (request) {
    final traced = startServerSpan(
      method: request.method,
      url: request.requestedUri,
      header: (name) => request.headers.value(name),
      clientAddress: _clientAddress(request),
    );
    if (traced == null) {
      handler(request);
      return;
    }
    Timer? fallback;
    void done() {
      fallback?.cancel();
      traced.finish(statusCode: request.response.statusCode);
    }

    try {
      unawaited(request.response.done.then((_) => done(), onError: (Object _) => done()));
    } catch (_) {}
    void failed(Object error, StackTrace stack) {
      traced.fail(error, stack);
      // A handler that failed may never close its response: the span ends anyway.
      fallback ??= Zone.root.createTimer(const Duration(seconds: 30), traced.finish);
    }

    traced.run(() => runCapturingOutput(() {
          final FutureOr<void> result;
          try {
            result = handler(request);
          } catch (error, stack) {
            failed(error, stack);
            rethrow;
          }
          if (result is Future<void>) {
            result.then((_) {}, onError: (Object error, StackTrace stack) {
              failed(error, stack);
              // Uncaught, as it would have been without Zharp.
              Zone.current.handleUncaughtError(error, stack);
            });
          }
        }));
  };
}

String? _clientAddress(HttpRequest request) {
  try {
    return request.connectionInfo?.remoteAddress.address;
  } catch (_) {
    return null;
  }
}
