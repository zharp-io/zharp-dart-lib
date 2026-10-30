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

Logs only — no spans, no trace headers on requests, `startSpan` just runs its callback:
`ZharpOptions(key: 'zpk_…', tracing: false)`.

## Develop

```bash
dart pub get && dart test
# End to end against a running Zharp (the key comes from the environment; never commit one):
ZHARP_KEY=zpk_… ZHARP_ENDPOINT=http://localhost:3000/api/v1/otlp dart run tool/e2e.dart
```
