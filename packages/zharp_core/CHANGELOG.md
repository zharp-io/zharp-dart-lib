## 0.3.0 - 2026-11-17

## 0.4.1 - 2026-11-22

- Flutter web: errors from release (dart2js) builds are named by what they are (`StateError`, `TypeError`, …) instead of a minified class name like `minified:dn`.
- Flutter web: errors carry the debug IDs of the `.js` files in their stack, so a build injected and uploaded with `zharp sourcemaps upload build/web` shows Dart file names and lines.

## 0.4.0 - 2026-11-21

- Request and response headers on HTTP client spans; secrets are sent as `[Filtered]`.

- **Behaviour change:** logs are off unless `logs` is on (`ZHARP_LOGS=true`). On a server, lines printed during a request end with `trace_id=… span_id=…` and the Zharp agent brings them in; errors, traces and `Zharp.log` are sent as before.

- Dart servers: a SERVER span per incoming request, without `startSpan`. `zharpHandler` (from
  `package:zharp_core/server.dart`) wraps an HttpServer handler; `zharp_shelf` covers shelf and
  dart_frog. The span continues the caller's `traceparent`, carries its `baggage` session and user,
  OpenTelemetry's HTTP server attributes, and fails on 5xx or a thrown error (reported, in its
  trace). The handler runs with the span current, so logs, child spans, outgoing requests,
  `setUser` (per request) and the stamp on printed lines all belong to it. `setRequestRoute`
  names the route. `sampleRate` and the caller's sampled flag apply; lines are stamped either way.
- `ZharpOptions.logs` (`ZHARP_LOGS`), **off by default**: nothing the program logs or prints is
  sent unless it is on. On a server the Zharp agent reads the program's output and brings those
  lines in; sending them from the SDK too made every line arrive twice. Errors, traces, sessions
  and `zharp.log` calls are sent either way.
- `ZharpOptions.logCorrelation` (`ZHARP_LOG_CORRELATION`), on by default, Dart servers and tools
  only: inside `ZharpCore.run`, every line printed during a span ends with
  ` trace_id=<32 hex> span_id=<16 hex>` (a JSON line gets the two as fields), so Zharp links the
  agent's copy to its request. Lines outside a span or already carrying a trace_id are unchanged.
- `ZharpCore.run(body)`, and with logs on, `ZharpOptions.captureOutput` (on by default;
  `ZHARP_CAPTURE_OUTPUT=false` turns it off): what the program prints is sent as logs, tied to
  the span it was written in, still printed as before. `package:logging` records with their
  level and `log.logger`; inside `ZharpCore.run`, `print` and `stdout`/`stderr` too. The level is read from the line (JSON `level`, `ERROR`,
  `[warn]`, `level=error`, `SEVERE`, the `logger` package's `[E]`/emoji — its boxes become one
  record), else info, or warning on stderr. Lines are capped at 32 KB, colour codes dropped, an
  unfinished line sent after 200 ms, and a line already sent is never sent twice.
- New dependency: `package:logging`.

## 0.2.0

- `ZharpOptions.captureBodies` (`CaptureBodies()` / `CaptureBodies.all()`): request and response
  bodies on `ZharpHttpClient` spans, off by default — failed requests only unless `all`. Field
  names kept, secret-looking values `[Filtered]` (nested objects keep their keys), files in
  uploads, inline images and binary bodies described, text capped at 32 KB (`maxSize`, up to
  128 KB). The span keeps the time the response arrived. Same rules as the JS SDKs.
- `url.full`: the secret query keys now follow the shared rules (`token`, `key`, `sig`, `code`,
  `state`, `password`, …) used by every Zharp SDK.

## 0.1.0

- First release: the engine behind `zharp_flutter` and `zharp_dio`. Spans, logs and errors as
  OTLP/HTTP JSON (gzipped), batched, retried with backoff, buffered in memory while offline;
  sessions; W3C `traceparent` + `baggage` for the hosts in `tracingOrigins`; `ZharpHttpClient`
  for `package:http`.
- `ZharpOptions(tracing: false)`: logs only — no spans, no trace headers; logs and errors still sent.
- Obfuscated builds (`--obfuscate --split-debug-info`): the Dart VM's stack is sent exactly as
  written, header included (`build_id`, `os`/`arch`, `isolate_dso_base`), with
  `zharp.dart_build_id`, `zharp.dart_os` and `zharp.dart_arch` on the error, so Zharp can
  symbolicate it with the uploaded symbols. Repeated-error detection keys on the first frame, not
  the header (which made different errors with the same message look like repeats).
