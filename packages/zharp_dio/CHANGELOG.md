## 0.2.0

- `captureBodies`: request and response bodies on Dio spans — `data`, `FormData` (files
  described), bytes and decoded responses — redacted and capped the same way as `zharp_core`.

## 0.1.0

- First release: `ZharpDioInterceptor` — a CLIENT span per Dio request, trace headers for
  `tracingOrigins`.
