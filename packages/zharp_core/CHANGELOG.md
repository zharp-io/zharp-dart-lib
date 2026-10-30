## 0.1.0

- First release: the engine behind `zharp_flutter` and `zharp_dio`. Spans, logs and errors as
  OTLP/HTTP JSON (gzipped), batched, retried with backoff, buffered in memory while offline;
  sessions; W3C `traceparent` + `baggage` for the hosts in `tracingOrigins`; `ZharpHttpClient`
  for `package:http`.
