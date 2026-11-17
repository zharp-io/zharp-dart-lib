## Unreleased

- `ZharpOptions.captureOutput` (on by default; `ZHARP_CAPTURE_OUTPUT=false` turns it off): what
  the program prints is sent as logs, tied to the span it was written in, still printed as before.
  `package:logging` records always, with their level and `log.logger`; inside `ZharpCore.run`,
  `print` and `stdout`/`stderr` too. The level is read from the line (JSON `level`, `ERROR`,
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
