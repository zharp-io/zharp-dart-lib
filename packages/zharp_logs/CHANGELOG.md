## 0.1.2

- **Errors you log carry their stack, with no extra code.** `ZharpLogger.error(e)` sends the
  stack an `Error` was thrown with; an `Exception` (which carries none) gets the stack from where
  it was logged, starting at your code. An error in the metadata — `{'err': e}` — is sent as its
  type, message and stack, and its stack becomes the log's. A `stack` you pass yourself is kept.

## 0.1.1

- Description: this package is for Dart servers, CLIs and the web; Flutter apps use
  `zharp_logs_flutter`.

## 0.1.0

- First release: `ZharpLogger.init()` with configuration from code, `--dart-define` or the
  environment; `debug`/`info`/`warn`/`error`/`fatal`, `log`, `captureException`, `setContext`;
  batched delivery with retries, cut to 1 MB per request; `guard()` for uncaught errors and
  `capturePrint`.
