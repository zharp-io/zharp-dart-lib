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

### Logs on a server

Wrap the program in `ZharpCore.run`:

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
