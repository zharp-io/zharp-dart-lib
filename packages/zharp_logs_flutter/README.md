# zharp_logs_flutter

Send your Flutter app's logs to [Zharp](https://zharp.io). Crashes — Flutter framework errors and
uncaught async errors — are sent automatically; everything else you log yourself, from anywhere in
your code. Works on Android, iOS, web, macOS, Windows and Linux.

Full documentation: [zharp.io/docs/sdks/logs](https://zharp.io/docs/sdks/logs)

---

## 1. Install

```bash
flutter pub add zharp_logs_flutter
```

## 2. Get an API key

1. In Zharp, open **Integrations & API** and choose **Main API keys**.
2. Click **Create API key**, give it a name, and tick **Ingest only**. That key can send logs but
   can't read anything, so it's safe to ship inside your app.
3. Click **Create key** and copy the key — it's shown only once.

<p>
  <img src="https://www.zharp.io/images/docs/api-key-create.png" alt="Create API key, with Ingest only ticked" width="48%">
  <img src="https://www.zharp.io/images/docs/api-key-created.png" alt="The new key, shown once with a Copy button" width="48%">
</p>

## 3. Start it

Call `ZharpFlutter.init()` first thing in `main()`, before `runApp`:

```dart
import 'package:flutter/material.dart';
import 'package:zharp_logs_flutter/zharp_logs_flutter.dart';

void main() {
  ZharpFlutter.init(
    apiKey: 'your-ingest-only-key',
    service: 'shop-app',
    environment: 'production',
    appVersion: '2.3.0',
  );
  runApp(const MyApp());
}
```

Rather keep the key out of your code? Leave it out and pass it when you build:

```bash
flutter run --dart-define=ZHARP_API_KEY=your-ingest-only-key --dart-define=ZHARP_SERVICE=shop-app
flutter build apk --dart-define=ZHARP_API_KEY=your-ingest-only-key --dart-define=ZHARP_SERVICE=shop-app --dart-define=ZHARP_ENV=production
```

```dart
ZharpFlutter.init();
```

What you pass to `init()` wins; anything you leave out is read from `--dart-define`. When it starts,
it prints one line so you know it's working:

```
[Zharp] Logging active — service "shop-app", environment "production"
```

## 4. Log

Anywhere in your app:

```dart
ZharpLogger.info('Checkout opened', {'cartItems': 3});
ZharpLogger.warn('Slow network detected', {'latencyMs': 3200});
ZharpLogger.error('Payment failed', {'orderId': 99});
```

`debug` and `fatal` are there too. For an error you caught, with its stack:

```dart
try {
  await checkout();
} catch (e, stack) {
  ZharpLogger.captureException(e, stack, metadata: {'step': 'checkout'});
}
```

When a user signs in, add their ID to every log:

```dart
ZharpLogger.setContext({'userId': user.id});
```

## 5. See your logs

Sign in at [zharp.io](https://zharp.io/login), open **Logs**, and pick your service in the
service dropdown.

![The Logs page on zharp.io](https://www.zharp.io/images/docs/logs-dashboard.png)

---

## What's sent automatically

- **Crashes**: Flutter framework errors (`FlutterError.onError` — build, layout and paint errors)
  and uncaught async errors (`PlatformDispatcher.onError`), as `error` logs with their stack. Errors
  Flutter marks as silent, like an image that failed to load, are sent as `warn`. Handlers your app
  already set are kept and still run. Turn this off with `captureErrors: false`.
- **Queued logs when the app goes to the background**, the last moment a mobile app is reliably
  running. Turn this off with `flushOnBackground: false`.
- **`debugPrint` output — only if you ask**, with `capturePrint: true`.

Every log carries a session ID (the same for one run of the app), the platform, the build mode
(`debug`, `profile` or `release`), and the OS and Dart version.

## Options

| Option | `--dart-define` | Default |
|---|---|---|
| `apiKey` | `ZHARP_API_KEY` | — |
| `service` | `ZHARP_SERVICE` | `unknown-service` |
| `environment` | `ZHARP_ENV` | none |
| `appVersion` | `ZHARP_VERSION` | none |
| `source` | `ZHARP_SOURCE` | none |
| `captureErrors` | — | on |
| `flushOnBackground` | — | on |
| `capturePrint` | `ZHARP_CAPTURE_PRINT` | off |
| `flushInterval` | — | 5 seconds |
| `maxBatchSize` | — | `50` |
| `endpoint` | `ZHARP_ENDPOINT` | `https://api.zharp.io/api/v1` |

`--dart-define=ZHARP_DISABLED=true` turns the SDK off.

## Dart without Flutter

For servers and CLIs, use [`zharp_logs`](https://pub.dev/packages/zharp_logs) — same API, no
Flutter.

## License

MIT © [Zharp](https://zharp.io)
