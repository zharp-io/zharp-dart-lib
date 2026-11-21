## 0.3.0 - 2026-11-17

## 0.4.0 - 2026-11-21

- Request and response headers on Dio spans; secrets are sent as `[Filtered]`.

- Requires zharp_core 0.3.0. Dio calls made while handling a server request are children of that request's span. Logs are off unless `logs` is on.

## 0.2.0

- `captureBodies`: request and response bodies on Dio spans — `data`, `FormData` (files
  described), bytes and decoded responses — redacted and capped the same way as `zharp_core`.

## 0.1.0

- First release: `ZharpDioInterceptor` — a CLIENT span per Dio request, trace headers for
  `tracingOrigins`.
