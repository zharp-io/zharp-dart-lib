/// Traces Dio requests for Zharp.
///
/// ```dart
/// final dio = Dio()..interceptors.add(ZharpDioInterceptor());
/// ```
library;

import 'package:dio/dio.dart';
import 'package:zharp_core/zharp_core.dart';

/// Records each request as a CLIENT span — joined to the screen or span it was made in — and
/// sends `traceparent` and `baggage` to the hosts in `tracingOrigins`, so your back end's spans
/// join the app's trace.
///
/// Add it once; it does nothing until `Zharp.init` has run, and never fails a request.
class ZharpDioInterceptor extends Interceptor {
  static const String _key = 'zharp.http_span';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      final headers = <String, String>{
        for (final entry in options.headers.entries)
          if (entry.value != null) entry.key: '${entry.value}',
      };
      final traced = startHttpSpan(options.method, options.uri, existingHeaders: headers);
      if (traced != null) {
        traced.headers.forEach((name, value) {
          options.headers.removeWhere((key, _) => key.toLowerCase() == name);
          options.headers[name] = value;
        });
        options.extra[_key] = traced;
      }
    } catch (_) {
      // Never fail a request because of monitoring.
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _finish(response.requestOptions, statusCode: response.statusCode);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    _finish(err.requestOptions, statusCode: status, error: status == null ? err : null);
    handler.next(err);
  }

  void _finish(RequestOptions options, {int? statusCode, Object? error}) {
    try {
      final traced = options.extra.remove(_key);
      if (traced is HttpSpan) {
        if (error is DioException) traced.span.setAttribute('dio.exception.type', error.type.name);
        traced.finish(statusCode: statusCode, error: error);
      }
    } catch (_) {
      // Never into the host app.
    }
  }
}
