import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bodies.dart';
import 'headers.dart';
import 'core.dart';
import 'otlp.dart';
import 'span.dart';

/// [url] as it is recorded: no user info, no fragment, secret-looking query values (`token`,
/// `key`, `sig`, `password`, … — the same rules as every Zharp SDK) filtered.
String redactUrl(Uri url) {
  try {
    final query = url.hasQuery
        ? url.query.split('&').map((pair) {
            return redactQuery(pair);
          }).join('&')
        : null;
    // Assembled by hand: Uri would percent-encode the [Filtered] marker.
    final port = url.hasPort ? ':${url.port}' : '';
    return '${url.scheme}://${url.host}$port${url.path}${query != null ? '?$query' : ''}';
  } catch (_) {
    return '${url.scheme}://${url.host}${url.path}';
  }
}

/// A traced outgoing request: its CLIENT span and the headers to add to it.
class HttpSpan {
  HttpSpan(this.span, this.headers, [this.bodies, this.headerRedact]);

  final ZharpSpan span;

  /// `captureBodies` for this request, or null when its bodies aren't captured.
  final BodySettings? bodies;

  /// `traceparent` and `baggage` — empty when the host isn't in `tracingOrigins`.
  final Map<String, String> headers;

  /// `captureHeaders`' extra secret names, or null when headers aren't recorded.
  final List<Pattern>? headerRedact;

  /// The headers that went out (`request`, the trace headers included) or came back (`response`).
  void recordHeaders(String side, Iterable<MapEntry<String, String>> headers) {
    final redact = headerRedact;
    if (redact == null) return;
    try {
      span.setAttributes(headerAttributes(side, headers, redact));
    } catch (_) {
      // Never into the host app.
    }
  }

  /// Whether this request's bodies are kept, given its outcome (null status: no response).
  bool wantsBodies(int? statusCode) => bodies?.wanted(statusCode) ?? false;

  /// End the span with the response status, or the error the request failed with. [attributes]
  /// are the bodies; [endTime] the time the response arrived, when the body was read after it.
  void finish({int? statusCode, Object? error, Map<String, Object?> attributes = const {}, DateTime? endTime}) {
    try {
      if (attributes.isNotEmpty) span.setAttributes(attributes);
      if (statusCode != null) {
        span.setAttribute('http.response.status_code', statusCode);
        // For a client, 4xx is a failure too: the request didn't do what the app wanted.
        if (statusCode >= 400) {
          span.setAttribute('error.type', '$statusCode');
          span.setError('HTTP $statusCode');
        }
      } else if (error != null) {
        span.setAttribute('error.type', error.runtimeType.toString());
        span.setError(_describe(error));
      }
      span.end(endTime);
    } catch (_) {
      // Never into the host app.
    }
  }

  static String _describe(Object error) {
    final text = error.toString();
    return text.length > 500 ? text.substring(0, 500) : text;
  }
}

/// Start a CLIENT span for a request, under the current span. Null when the SDK isn't running or
/// [url] is Zharp's own endpoint, or when `tracing` is off (logs-only mode). [existingHeaders] are the request's headers: a `traceparent`
/// already there is left alone and `baggage` is merged with.
HttpSpan? startHttpSpan(String method, Uri url, {Map<String, String> existingHeaders = const {}}) {
  final core = ZharpCore.instance;
  if (core == null || !core.options.tracing) return null;
  try {
    if (core.isOwnEndpoint(url)) return null;
    final verb = method.toUpperCase();
    final span = core.tracer.start(
      '$verb ${url.host}${url.path.isEmpty ? '/' : url.path}',
      kind: SpanKind.client,
      attributes: {
        'http.request.method': verb,
        'url.full': redactUrl(url),
        'server.address': url.host,
        if (url.hasPort) 'server.port': url.port,
      },
    );
    final lower = {for (final entry in existingHeaders.entries) entry.key.toLowerCase(): entry.value};
    final headers = Map.of(core.propagationHeaders(url, span, existingBaggage: lower['baggage']));
    if (lower.containsKey('traceparent')) headers.remove('traceparent');
    if (!headers.containsKey('traceparent')) headers.remove('baggage');
    final capture = core.options.captureBodies;
    final bodies = capture == null ? null : BodySettings(capture);
    return HttpSpan(span, headers, bodies != null && bodies.allows(url) ? bodies : null,
        core.options.captureHeaders ? core.options.redactHeaders : null);
  } catch (_) {
    return null;
  }
}

/// A `package:http` client that traces every request as a CLIENT span — joined to the screen or
/// span it was made in — and sends `traceparent` and `baggage` to the hosts in
/// `tracingOrigins`, so your back end's spans join the same trace.
///
/// ```dart
/// final client = ZharpHttpClient();            // or ZharpHttpClient(myClient)
/// final response = await client.get(Uri.parse('https://api.example.com/orders'));
/// ```
///
/// Before `Zharp.init` (or when it's disabled) requests pass straight through.
class ZharpHttpClient extends http.BaseClient {
  ZharpHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final traced = startHttpSpan(request.method, request.url, existingHeaders: request.headers);
    if (traced == null) return _inner.send(request);
    try {
      _setHeaders(request, traced.headers);
    } catch (_) {
      // A request already finalized can't take headers; it is still traced.
    }
    traced.recordHeaders('request', request.headers.entries);
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      traced.finish(error: error, attributes: traced.wantsBodies(null) ? _safely(() => _requestAttributes(request, traced.bodies!)) : const {});
      rethrow;
    }
    traced.recordHeaders('response', response.headers.entries);
    if (!traced.wantsBodies(response.statusCode)) {
      traced.finish(statusCode: response.statusCode);
      return response;
    }
    return _withResponseBody(traced, request, response);
  }

  /// The response handed to the app, its body seen on the way through: the span ends when the app
  /// has read it (or 3 seconds after it arrived, with what was read by then), at the time it arrived.
  http.StreamedResponse _withResponseBody(HttpSpan traced, http.BaseRequest request, http.StreamedResponse response) {
    final bodies = traced.bodies!;
    final arrived = traced.span.now();
    final sent = _safely(() => _requestAttributes(request, bodies));
    final type = response.headers['content-type'];
    if (!isTextual(type)) {
      final size = response.contentLength;
      traced.finish(
          statusCode: response.statusCode,
          attributes: {...sent, if (size != 0) ...describedAttributes('response', type, size: size)});
      return response;
    }

    final kept = <int>[];
    var cut = false;
    var done = false;
    late final Timer timer;
    void complete({required bool ended}) {
      if (done) return;
      done = true;
      timer.cancel();
      final got = _safely(() => bytesAttributes('response', kept, type, bodies, cut: cut || (!ended && kept.isNotEmpty)));
      traced.finish(statusCode: response.statusCode, attributes: {...sent, ...got}, endTime: arrived);
    }

    timer = Timer(const Duration(seconds: 3), () => complete(ended: false));
    final stream = response.stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (data, sink) {
        if (!cut) {
          final room = bodies.rawLimit - kept.length;
          if (data.length > room) {
            kept.addAll(data.take(room));
            cut = true;
          } else {
            kept.addAll(data);
          }
        }
        sink.add(data);
      },
      handleError: (error, stack, sink) {
        complete(ended: false);
        sink.addError(error, stack);
      },
      handleDone: (sink) {
        complete(ended: true);
        sink.close();
      },
    ));
    return http.StreamedResponse(
      http.ByteStream(stream),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The request body's attributes: text kept, a form upload as its fields with each file
  /// described, a streamed body described.
  static Map<String, Object?> _requestAttributes(http.BaseRequest request, BodySettings bodies) {
    final type = request.headers['content-type'];
    if (request is http.Request) {
      final bytes = request.bodyBytes;
      if (bytes.isEmpty) return const {};
      final limit = bodies.rawLimit;
      return bytesAttributes('request', bytes.length > limit ? bytes.sublist(0, limit) : bytes, type, bodies,
          cut: bytes.length > limit, total: bytes.length);
    }
    if (request is http.MultipartRequest) {
      final fields = <String, Object?>{...request.fields};
      for (final file in request.files) {
        final label = fileLabel(file.filename, file.contentType.mimeType, file.length);
        final existing = fields[file.field];
        fields[file.field] = existing == null ? label : existing is List ? [...existing, label] : [existing, label];
      }
      return bodyAttributes('request', jsonEncode(fields), 'multipart/form-data', bodies);
    }
    final size = request.contentLength;
    return size != null && size > 0 ? describedAttributes('request', type, size: size) : const {};
  }

  static Map<String, Object?> _safely(Map<String, Object?> Function() body) {
    try {
      return body();
    } catch (_) {
      return const {};
    }
  }

  void _setHeaders(http.BaseRequest request, Map<String, String> headers) {
    headers.forEach((name, value) {
      // Replace a header the app set under another capitalisation rather than send both.
      request.headers.removeWhere((key, _) => key.toLowerCase() == name);
      request.headers[name] = value;
    });
  }

  @override
  void close() => _inner.close();
}
