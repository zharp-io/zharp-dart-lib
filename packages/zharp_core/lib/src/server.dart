/// Incoming requests on a Dart server: a SERVER span each, and the zone the handler runs in.
///
/// The framework adapters (`zharpHandler` for `dart:io`'s HttpServer, `zharp_shelf`) call
/// [startServerSpan] and run the handler with [ServerRequest.run], so everything done while
/// handling a request — `zharp.log`, child spans, outgoing traced requests, `setUser`, and the
/// trace ids stamped on printed lines — belongs to that request.
library;

import 'dart:async';

import 'bodies.dart';
import 'core.dart';
import 'otlp.dart';
import 'propagation.dart';
import 'span.dart';

/// What the request being handled carries besides its span: the caller's `session.id` and
/// `enduser.id` (from its `baggage`), and the user `setUser` named while handling it.
class RequestScope {
  RequestScope(this.baggage, [this.method = '', this.recording = true]);

  /// The request's method, `GET`.
  final String method;

  /// Whether its span is recorded (false in logs-only mode).
  final bool recording;

  /// `session.id` / `enduser.id` from the caller's baggage.
  final Map<String, String> baggage;

  /// The request's span, once started (null in logs-only mode without a caller's trace).
  ZharpSpan? span;

  ZharpUser? user;

  /// Whether `setUser` / `clearUser` was called for this request.
  bool userSet = false;

  void setUser(ZharpUser? user) {
    this.user = user;
    userSet = true;
    // The request's span is still open: it learns the user too.
    final open = span;
    if (open != null && user != null) open.setAttributes(userAttributes(user));
  }

  /// The route template the request matched (`/users/<id>`): the span becomes `METHOD route`.
  void setRoute(String? route) {
    final open = span;
    if (open == null || route == null || route.isEmpty || !recording || open.isEnded) return;
    open.setAttribute('http.route', route);
    open.updateName('${method.isEmpty ? '' : '$method '}$route');
  }

  static final Object _key = Object();

  static RequestScope? of(Zone zone) {
    final value = zone[_key];
    return value is RequestScope ? value : null;
  }

  static RequestScope? get current => of(Zone.current);
}

/// A user as attributes.
Map<String, Object> userAttributes(ZharpUser? user) => {
      if (user != null) 'enduser.id': user.id,
      if (user?.email != null) 'enduser.email': user!.email!,
      if (user?.name != null) 'enduser.name': user!.name!,
    };

const List<String> _baggageKeys = ['session.id', 'enduser.id'];

/// An incoming request being traced. See [startServerSpan].
class ServerRequest {
  ServerRequest._(this._core, this.method, this.scope, this.span, this._recording);

  final ZharpCore _core;
  final String method;
  final RequestScope scope;

  /// The SERVER span, or null in logs-only mode without a caller's trace. With tracing off and a
  /// `traceparent`, a span that carries the caller's ids (so logs and printed lines join its
  /// trace) and is never sent.
  final ZharpSpan? span;
  final bool _recording;
  bool _finished = false;

  /// Run [body] — the handler — as this request: its span current, its baggage and user in
  /// context.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {
        RequestScope._key: scope,
        if (span != null) spanZoneKey: span,
      });

  /// The route template the request matched (`/users/<id>`): the span becomes `METHOD route`.
  void setRoute(String? route) => scope.setRoute(route);

  /// The handler failed: [error] is reported as an unhandled error (once), in the request's
  /// trace, and marks the span failed. The span still ends in [finish].
  void fail(Object error, StackTrace? stackTrace) {
    try {
      run(() => _core.captureError(error,
          stackTrace: stackTrace, handled: false, attributes: {'zharp.mechanism': 'http.server'}));
      final open = span;
      if (open == null || !_recording || open.isEnded) return;
      open.setAttribute('error.type', error.runtimeType.toString());
      open.setError(_describe(error));
    } catch (_) {
      // Never into the app.
    }
  }

  /// End the span with the response's status — an error for 5xx. Only the first call counts.
  void finish({int? statusCode}) {
    if (_finished) return;
    _finished = true;
    try {
      final open = span;
      if (open == null || !_recording) return;
      if (statusCode != null) {
        open.setAttribute('http.response.status_code', statusCode);
        // For a server only 5xx is its failure; 4xx is the caller's.
        if (statusCode >= 500 && open.status != SpanStatusCode.error) {
          open.setAttribute('error.type', '$statusCode');
          open.setError('HTTP $statusCode');
        }
      }
      open.end();
    } catch (_) {
      // Never into the app.
    }
  }

  static String _describe(Object error) {
    String text;
    try {
      text = error.toString();
    } catch (_) {
      text = error.runtimeType.toString();
    }
    return text.length > 500 ? text.substring(0, 500) : text;
  }
}

/// Start tracing an incoming request: a SERVER span named `METHOD path` (or `METHOD route` when
/// [route] is known) that continues the caller's trace from its `traceparent`, with its
/// `session.id` and `enduser.id` from `baggage`. [header] reads a request header by its
/// lower-case name. Null before Zharp starts.
ServerRequest? startServerSpan({
  required String method,
  required Uri url,
  required String? Function(String name) header,
  String? route,
  String? clientAddress,
}) {
  final core = ZharpCore.instance;
  if (core == null) return null;
  try {
    final verb = method.toUpperCase();
    final baggage = <String, String>{};
    final parsed = parseBaggage(header('baggage'));
    for (final key in _baggageKeys) {
      final value = parsed[key]?.trim();
      if (value != null && value.isNotEmpty) baggage[key] = value;
    }
    final recording = core.options.tracing;
    final scope = RequestScope(baggage, verb, recording);
    final parent = parseTraceparent(header('traceparent'));
    final path = url.path.isEmpty ? '/' : url.path;

    ZharpSpan? span;
    if (recording) {
      final host = header('host');
      final userAgent = header('user-agent');
      final query = url.hasQuery ? redactQuery(url.query) : null;
      // Started inside the request's zone, so it carries the request's context, not the process's.
      span = runZoned(
        () => core.tracer.start(
          '$verb ${route ?? path}',
          kind: SpanKind.server,
          root: true,
          remoteParent: parent,
          attributes: {
            'http.request.method': verb,
            'url.path': path,
            if (query != null && query.isNotEmpty) 'url.query': query,
            if (url.scheme.isNotEmpty) 'url.scheme': url.scheme,
            if (route != null) 'http.route': route,
            if (host != null && host.isNotEmpty) 'server.address': _hostOnly(host),
            if (url.hasPort) 'server.port': url.port,
            if (clientAddress != null) 'client.address': clientAddress,
            if (userAgent != null && userAgent.isNotEmpty) 'user_agent.original': userAgent,
          },
        ),
        zoneValues: {RequestScope._key: scope},
      );
    } else if (parent != null) {
      // Logs only: no span is made or sent, but the request's logs carry the caller's trace.
      span = ZharpSpan.internal(
        traceId: parent.traceId,
        spanId: parent.spanId,
        parentSpanId: null,
        name: '$verb $path',
        kind: SpanKind.server,
        sampled: false,
        startMicros: 0,
        attributes: {},
        onEnd: (_) {},
        clock: DateTime.now,
      );
    }
    scope.span = span;
    return ServerRequest._(core, verb, scope, span, recording);
  } catch (_) {
    return null;
  }
}

String _hostOnly(String host) {
  final value = host.trim();
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    return close > 0 ? value.substring(1, close) : value;
  }
  final colon = value.lastIndexOf(':');
  return colon > 0 ? value.substring(0, colon) : value;
}

/// Name the route the request being handled matched — its template, `/users/<id>`, not the
/// path — so its span is `GET /users/<id>` and requests group by route. Call it from the handler
/// (shelf_router doesn't tell middleware which route matched). Does nothing outside a request.
void setRequestRoute(String route) => RequestScope.current?.setRoute(route);
