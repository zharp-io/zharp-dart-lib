# zharp_core

The engine behind [`zharp_flutter`](../zharp_flutter) and [`zharp_dio`](../zharp_dio): spans,
logs, errors and sessions, sent to Zharp Application Monitoring as OTLP/HTTP JSON.

**Building a Flutter app? Add `zharp_flutter`** — it starts this for you and adds Flutter's
error capture, screen views and lifecycle handling.

It is pure Dart (no Flutter), so it also works in CLIs and on the web:

```dart
import 'package:zharp_core/zharp_core.dart';

final zharp = ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'my-tool'))!;
zharp.log.info('Started');
await zharp.startSpan('import', (span) async { /* … */ });
await zharp.close();
```

## Dart servers

Every incoming request gets a SERVER span without the app calling `startSpan`, named `METHOD`
(`GET`) — or `METHOD route` (`GET /users/<id>`) once the route is known — with the path in
`url.path`:

- **dart:io `HttpServer`** — wrap the handler you pass to `listen`:

  ```dart
  import 'package:zharp_core/server.dart';

  void main() => ZharpCore.run(() async {
    ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'api'));
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    server.listen(zharpHandler((request) async {
      request.response.write('ok');
      await request.response.close();
    }));
  });
  ```

- **shelf, dart_frog** — [`zharp_shelf`](../zharp_shelf)'s `zharpMiddleware()`.
- **Serverpod** — not covered yet: its endpoints don't run through shelf. Wrap work in
  `zharp.startSpan` meanwhile.

Each span continues the caller's trace (`traceparent`) and carries its `session.id` and
`enduser.id` (`baggage`, sent by Zharp's browser SDK); `http.request.method`, `url.path`,
`url.query` (secret-looking values `[Filtered]`), `http.response.status_code`, `http.route`,
`server.address`, `client.address`, `user_agent.original`. A 5xx, or an error the handler throws,
fails the span; the error is reported, in the request's trace. `sampleRate` and the caller's
sampled flag decide which traces are sent; lines are stamped either way. Name the route a
request matched with `setRequestRoute('/users/<id>')` from the handler, so its span is named
by route; without one, the span is just `GET` (a path full of ids would name every request
differently).

The handler runs with the request's span current: `zharp.log`, `startSpan`, traced outgoing
requests (`ZharpHttpClient`, `zharp_dio`, which pass the trace on) and `setUser` — which names
that request's user, not the process's — all belong to the request. Request bodies aren't
captured (`captureBodies` covers outgoing requests only).

### Logs on a server

Wrap the program in `ZharpCore.run`, as above (`zharpHandler` and `zharpMiddleware` also do it
for each request):

```dart
void main() => ZharpCore.run(() async {
  ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'api'));
  await serve();
});
```

On a server, the app's logs come in through the **Zharp agent**, which reads the app's output
(its container's logs, its log files). The SDK doesn't send them too — logs are off by default —
it stamps them: every line printed during a span (`print`, `stdout`, `stderr`, so also
`package:logging` listeners, the `logger` package and shelf's request log) ends with
` trace_id=<32 hex> span_id=<16 hex>`, and a JSON line gets `"trace_id"` and `"span_id"` fields,
so Zharp links each line the agent collects to its request. Lines printed outside a span and
lines that already carry a `trace_id` are left as they are. `logCorrelation: false` (or
`ZHARP_LOG_CORRELATION=false`) turns the stamp off. Errors, traces and `zharp.log` calls are sent
by the SDK either way.

Where there's no agent, turn logs on — `logs: true`, or `ZHARP_LOGS=true` — and what the program
logs and prints is sent by the SDK, each line tied to the span it was written in, and still
printed as before (with the stamp). `package:logging` records are then sent with their own
level and logger name even outside `ZharpCore.run`. A line's
level is read from the line (a JSON `level`, `ERROR`, `[warn]`, `level=error`, `SEVERE`, the
`logger` package's `[E]` or emoji), else info — warning on `stderr`. A line already sent
(`zharp.log`, a `package:logging` record the app also prints) isn't sent again. Not captured:
`dart:developer`'s `log()`, other isolates, and writes through a `stdout` reference taken before
`ZharpCore.run` started (or through `stdout.nonBlocking`). With logs on, `captureOutput: false`
(or `ZHARP_CAPTURE_OUTPUT=false`) sends only `zharp.log` calls.

Logs only — no spans, no trace headers on requests, `startSpan` just runs its callback:
`ZharpOptions(key: 'zpk_…', tracing: false)`.

## Develop

```bash
dart pub get && dart test
# End to end against a running Zharp (the key comes from the environment; never commit one):
ZHARP_KEY=zpk_… dart run tool/e2e.dart
```
