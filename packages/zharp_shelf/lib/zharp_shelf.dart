/// Traces shelf servers — and dart_frog, which runs on shelf — for Zharp.
///
/// ```dart
/// final handler = const Pipeline().addMiddleware(zharpMiddleware()).addHandler(router.call);
/// ```
library;

import 'dart:io' show HttpConnectionInfo;

import 'package:shelf/shelf.dart';
import 'package:zharp_core/server.dart';
import 'package:zharp_core/zharp_core.dart' show runCapturingOutput;

export 'package:zharp_core/server.dart' show setRequestRoute;

/// A SERVER span per request: `METHOD path` — `METHOD route` once the handler names its route
/// with [setRequestRoute] — continuing the caller's trace (`traceparent`) with its `session.id`
/// and `enduser.id` (`baggage`), ended with the response's status (an error for 5xx).
///
/// Inner handlers run with that span current, so `zharp.log`, `startSpan`, traced outgoing
/// requests (`ZharpHttpClient`, `zharp_dio`) and `setUser` belong to the request, and every line
/// printed while handling it ends with its `trace_id` and `span_id` (see
/// `ZharpOptions.logCorrelation`). An error a handler throws is reported, marks the span, and is
/// rethrown for shelf to answer 500 as before. Put it first in the pipeline. Before Zharp starts,
/// requests pass straight through.
Middleware zharpMiddleware() {
  return (Handler inner) {
    return (Request request) {
      final traced = startServerSpan(
        method: request.method,
        url: request.requestedUri,
        header: (name) => request.headers[name],
        clientAddress: _clientAddress(request),
      );
      if (traced == null) return inner(request);
      return traced.run(() => runCapturingOutput(() async {
            try {
              final response = await inner(request);
              traced.finish(statusCode: response.statusCode);
              return response;
            } on HijackException {
              // The connection was handed over (a WebSocket): the request is done here.
              traced.finish(statusCode: 101);
              rethrow;
            } catch (error, stack) {
              traced.fail(error, stack);
              // shelf answers an error with a 500.
              traced.finish(statusCode: 500);
              rethrow;
            }
          }));
    };
  };
}

String? _clientAddress(Request request) {
  try {
    final info = request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : null;
  } catch (_) {
    return null;
  }
}
