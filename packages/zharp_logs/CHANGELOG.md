## 0.1.0

- First release: `ZharpLogger.init()` with configuration from code, `--dart-define` or the
  environment; `debug`/`info`/`warn`/`error`/`fatal`, `log`, `captureException`, `setContext`;
  batched delivery with retries, cut to 1 MB per request; `guard()` for uncaught errors and
  `capturePrint`.
