/// Traces Dio requests for Zharp.
///
/// ```dart
/// final dio = Dio()..interceptors.add(ZharpDioInterceptor());
/// ```
library;

import 'dart:convert';

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
    _finish(response.requestOptions, statusCode: response.statusCode, response: response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    _finish(err.requestOptions, statusCode: status, error: status == null ? err : null, response: err.response);
    handler.next(err);
  }

  void _finish(RequestOptions options, {int? statusCode, Object? error, Response<dynamic>? response}) {
    try {
      final traced = options.extra.remove(_key);
      if (traced is HttpSpan) {
        if (error is DioException) traced.span.setAttribute('dio.exception.type', error.type.name);
        var attributes = const <String, Object?>{};
        if (traced.wantsBodies(statusCode)) {
          final bodies = traced.bodies!;
          attributes = {
            ..._safely(() => _requestAttributes(options, bodies)),
            if (response != null) ..._safely(() => _responseAttributes(response, bodies)),
          };
        }
        traced.finish(statusCode: statusCode, error: error, attributes: attributes);
      }
    } catch (_) {
      // Never into the host app.
    }
  }

  /// What the app sent, as Dio holds it: text and JSON kept, a `FormData` upload as its fields
  /// with each file described, bytes decoded when they are text, a stream described.
  static Map<String, Object?> _requestAttributes(RequestOptions options, BodySettings bodies) {
    final data = options.data;
    if (data == null) return const {};
    final type = options.contentType ?? _header(options.headers, 'content-type');
    if (data is FormData) {
      final fields = <String, Object?>{};
      void add(String name, Object value) {
        final existing = fields[name];
        fields[name] = existing == null ? value : existing is List ? [...existing, value] : [existing, value];
      }

      for (final field in data.fields) {
        add(field.key, field.value);
      }
      for (final file in data.files) {
        add(file.key, fileLabel(file.value.filename, _mimeOf(file.value.contentType), file.value.length));
      }
      return bodyAttributes('request', jsonEncode(fields), 'multipart/form-data', bodies);
    }
    if (data is String) return _text('request', data, type, bodies);
    if (data is List<int>) return _bytes('request', data, type, bodies);
    if (data is Map || data is List) {
      final form = (type ?? '').toLowerCase().contains('application/x-www-form-urlencoded');
      final text = form && data is Map ? Transformer.urlEncodeMap(Map<String, dynamic>.from(data)) : jsonEncode(data);
      return _text('request', text, type ?? Headers.jsonContentType, bodies);
    }
    if (data is Stream) return describedAttributes('request', type);
    return const {};
  }

  /// What came back, as Dio decoded it (`responseType`): text and JSON kept, bytes decoded when
  /// they are text, a stream described.
  static Map<String, Object?> _responseAttributes(Response<dynamic> response, BodySettings bodies) {
    final data = response.data;
    final type = response.headers.value('content-type');
    if (data == null) return const {};
    if (data is ResponseBody) {
      final size = int.tryParse(response.headers.value('content-length') ?? '');
      return describedAttributes('response', type, size: size);
    }
    if (!isTextual(type)) {
      final size = data is List<int> ? data.length : int.tryParse(response.headers.value('content-length') ?? '');
      return describedAttributes('response', type, size: size);
    }
    if (data is String) return _text('response', data, type, bodies);
    if (data is List<int>) return _bytes('response', data, type, bodies);
    if (data is Map || data is List) return _text('response', jsonEncode(data), type, bodies);
    return const {};
  }

  static Map<String, Object?> _text(String side, String text, String? type, BodySettings bodies) {
    if (!isTextual(type)) return describedAttributes(side, type, size: utf8.encode(text).length);
    final limit = bodies.rawLimit;
    return bodyAttributes(side, text.length > limit ? text.substring(0, limit) : text, type, bodies, cut: text.length > limit);
  }

  static Map<String, Object?> _bytes(String side, List<int> bytes, String? type, BodySettings bodies) {
    final limit = bodies.rawLimit;
    return bytesAttributes(side, bytes.length > limit ? bytes.sublist(0, limit) : bytes, type, bodies,
        cut: bytes.length > limit, total: bytes.length);
  }

  static String? _header(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name && entry.value != null) return '${entry.value}';
    }
    return null;
  }

  static String? _mimeOf(Object? contentType) {
    if (contentType == null) return null;
    try {
      return (contentType as dynamic).mimeType as String?;
    } catch (_) {
      return contentType.toString().split(';').first.trim();
    }
  }

  static Map<String, Object?> _safely(Map<String, Object?> Function() body) {
    try {
      return body();
    } catch (_) {
      return const {};
    }
  }
}
