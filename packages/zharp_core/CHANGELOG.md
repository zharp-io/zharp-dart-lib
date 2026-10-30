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
