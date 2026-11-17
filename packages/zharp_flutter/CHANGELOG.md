## 0.3.0 - 2026-11-17

- **Behaviour change:** logs are off unless `logs` is on (`ZHARP_LOGS=true`). On a server, lines printed during a request end with `trace_id=… span_id=…` and the Zharp agent brings them in; errors, traces and `Zharp.log` are sent as before.

- `ZharpOptions.logs` (`--dart-define=ZHARP_LOGS=true`), **off by default**: nothing the app
  logs or prints is sent unless it is on. Errors, traces, sessions and `Zharp.log` calls are sent
  either way. Lines are never stamped with trace ids in apps.
- With logs on, `ZharpOptions.captureOutput` (on by default): `debugPrint` and `package:logging`
  are sent as logs, and inside `Zharp.guard` also `print`, the `logger` package and `stdout`/`stderr` — each
  line tied to the trace and screen it was written in, still printed as before, never sent twice
  (Flutter's console dump of an error Zharp reported isn't sent again). See "Logs from what the
  app prints" in the README.

## 0.2.0

- `ZharpOptions.captureBodies`: request and response bodies on traced requests, off by default
  (see the README).

## 0.1.0

- First release of Zharp Application Monitoring for Flutter: `Zharp.init`, uncaught Flutter,
  platform and zone errors, `captureError`, `Zharp.log`, sessions, device context, screen views
  (`ZharpNavigatorObserver`), traced HTTP (`ZharpHttpClient`; Dio via `zharp_dio`), flush on pause.
- `ZharpOptions(tracing: false)`: logs only — no screen-view or HTTP spans, no trace headers.
- Readable stacks from obfuscated builds: see "Readable stack traces from obfuscated builds" in
  the README (`npx @zharp/cli dart-symbols upload build/symbols --app <id>`).
