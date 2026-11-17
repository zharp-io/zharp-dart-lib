# zharp_shelf

Zharp Application Monitoring for Dart servers on [shelf](https://pub.dev/packages/shelf) — and
[dart_frog](https://dartfrog.vgv.dev), which runs on shelf: a SERVER span per request that
continues the caller's trace, and the request's `trace_id`/`span_id` on every line it prints.

```bash
dart pub add zharp_core zharp_shelf
```

```dart
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:zharp_core/zharp_core.dart';
import 'package:zharp_shelf/zharp_shelf.dart';

void main() => ZharpCore.run(() async {
  ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'api', environment: 'production'));
  final handler = const Pipeline()
      .addMiddleware(zharpMiddleware()) // first, so it sees everything
      .addMiddleware(logRequests())
      .addHandler(router.call);
  await shelf_io.serve(handler, InternetAddress.anyIPv4, 8080);
});
```

## dart_frog

In `routes/_middleware.dart`:

```dart
import 'package:dart_frog/dart_frog.dart';
import 'package:zharp_shelf/zharp_shelf.dart';

Handler middleware(Handler handler) => handler.use(fromShelfMiddleware(zharpMiddleware()));
```

Start Zharp in a custom entrypoint (`main.dart` with `run`) before `serve`.

## What each request gets

- A SERVER span `METHOD path`; call `setRequestRoute('/users/<id>')` in the handler and it becomes
  `GET /users/<id>` with `http.route` (shelf_router doesn't tell middleware which route matched).
- The caller's trace from `traceparent`, and its `session.id`/`enduser.id` from `baggage`.
- `http.request.method`, `url.path`, `url.query` (secret-looking values `[Filtered]`),
  `http.response.status_code`, `server.address`, `client.address`, `user_agent.original`.
- A 5xx response, or an error a handler throws, fails the span; a thrown error is reported in the
  request's trace and rethrown, so shelf still answers 500.
- Everything done while handling it — `zharp.log`, `startSpan`, `ZharpHttpClient`/`zharp_dio`
  requests (which pass the trace on), `setUser` (for that request only) — belongs to it.
- Every line printed while handling it ends with ` trace_id=… span_id=…` (a JSON line gets the two
  as fields), so the Zharp agent's copy of your logs links to the request. Logs themselves are
  sent by the SDK only with `logs: true` — see [`zharp_core`](../zharp_core).

`sampleRate` and the caller's sampled flag decide which traces are sent; lines are stamped either
way. The span ends when the handler returns its response (a streamed body may still be sending).
Request and response bodies aren't captured.
