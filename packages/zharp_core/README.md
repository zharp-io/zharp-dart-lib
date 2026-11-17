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

### Logs from what the program prints

Wrap the program in `ZharpCore.run` and everything it prints is sent as logs too — `print`,
writes to `stdout` and `stderr`, `package:logging`, the `logger` package, shelf's request log —
each line tied to the span it was written in, and still printed exactly as before:

```dart
void main() => ZharpCore.run(() async {
  ZharpCore.start(ZharpOptions(key: 'zpk_…', service: 'api'));
  await serve();
});
```

`package:logging` records are sent with their own level and logger name even outside it. A line's
level is read from the line (a JSON `level`, `ERROR`, `[warn]`, `level=error`, `SEVERE`, the
`logger` package's `[E]` or emoji), else info — warning on `stderr`. A line already sent
(`zharp.log`, a `package:logging` record the app also prints) isn't sent again. Not captured:
`dart:developer`'s `log()`, other isolates, and writes through a `stdout` reference taken before
`ZharpCore.run` started (or through `stdout.nonBlocking`). `captureOutput: false`, or
`ZHARP_CAPTURE_OUTPUT=false` in the environment, turns it off.

Logs only — no spans, no trace headers on requests, `startSpan` just runs its callback:
`ZharpOptions(key: 'zpk_…', tracing: false)`.

## Develop

```bash
dart pub get && dart test
# End to end against a running Zharp (the key comes from the environment; never commit one):
ZHARP_KEY=zpk_… ZHARP_ENDPOINT=http://localhost:3000/api/v1/otlp dart run tool/e2e.dart
```
