import 'package:http/http.dart' as http;

import 'core.dart';
import 'otlp.dart';
import 'span.dart';

/// Query parameters whose values are replaced in `url.full`, so tokens don't end up in traces.
final RegExp _secretParam =
    RegExp(r'(token|key|secret|password|passwd|pwd|auth|sig|signature|session|code)', caseSensitive: false);

/// [url] as it is recorded: no user info, no fragment, secret-looking query values filtered.
String redactUrl(Uri url) {
  try {
    final query = url.hasQuery
        ? url.query.split('&').map((pair) {
            final eq = pair.indexOf('=');
            if (eq <= 0) return pair;
            final name = Uri.decodeQueryComponent(pair.substring(0, eq));
            return _secretParam.hasMatch(name) ? '${pair.substring(0, eq)}=[Filtered]' : pair;
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
  HttpSpan(this.span, this.headers);

  final ZharpSpan span;

  /// `traceparent` and `baggage` — empty when the host isn't in `tracingOrigins`.
  final Map<String, String> headers;

  /// End the span with the response status, or the error the request failed with.
  void finish({int? statusCode, Object? error}) {
    try {
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
      span.end();
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
    return HttpSpan(span, headers);
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
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error) {
      traced.finish(error: error);
      rethrow;
    }
    traced.finish(statusCode: response.statusCode);
    return response;
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
