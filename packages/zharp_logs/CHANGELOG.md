## 0.1.1

- Description: this package is for Dart servers, CLIs and the web; Flutter apps use
  `zharp_logs_flutter`.

## 0.1.0

- First release: `ZharpLogger.init()` with configuration from code, `--dart-define` or the
  environment; `debug`/`info`/`warn`/`error`/`fatal`, `log`, `captureException`, `setContext`;
  batched delivery with retries, cut to 1 MB per request; `guard()` for uncaught errors and
  `capturePrint`.
