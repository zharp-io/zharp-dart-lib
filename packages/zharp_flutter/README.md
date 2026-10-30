# zharp_flutter

Zharp Application Monitoring for Flutter: crashes and errors grouped into issues, logs, screen
views, traced HTTP requests and sessions — sent as OpenTelemetry (OTLP), joined to your back end's
traces.

```bash
flutter pub add zharp_flutter
```

```dart
import 'package:zharp_flutter/zharp_flutter.dart';

Future<void> main() async {
  await Zharp.init(ZharpOptions(
    key: 'zpk_…',                 // the app key from the Setup page; safe to ship
    service: 'shop-app',
    environment: 'production',
    tracingOrigins: ['api.example.com'], // your back end: requests there carry traceparent
  ));
  runApp(const MyApp());
}

// Once someone signs in, and on sign-out:
Zharp.setUser(id: user.id, email: user.email);
Zharp.clearUser();
```

## What it records

- **Uncaught errors** — `FlutterError.onError` and `PlatformDispatcher.onError` (handlers you set
  before are kept), with their Dart stack, as unhandled. Errors in your own zones:
  `Zharp.guard(() async { await Zharp.init(…); runApp(…); })`.
- **Caught errors** — `Zharp.captureError(error, stackTrace: stack, attributes: {…})`, as handled.
- **Logs** — `Zharp.log.debug/info/warn/error('message', {'key': value})`, tied to the current trace.
- **Screen views** — add `ZharpNavigatorObserver()` to `navigatorObservers` (or go_router's
  `observers`). Each named page route becomes a root span `screen <name>` that lasts until the
  screen is drawn and its requests have finished; everything recorded meanwhile carries
  `app.screen.name`.
- **HTTP** — `ZharpHttpClient()` (a `package:http` client; wrap your own with
  `ZharpHttpClient(inner)`), or for Dio, [`zharp_dio`](../zharp_dio)'s `ZharpDioInterceptor`. A
  CLIENT span per request; `traceparent` and `baggage` only for `tracingOrigins` hosts.
- **Your own spans** — `await Zharp.startSpan('checkout', (span) async { … })`.
- **Sessions** — `session.id` on everything; a new one after 30 minutes in the background or idle,
  and on `clearUser()`.
- **Device context** — `device.model.name`, `device.manufacturer`, `os.name`, `os.version`, and
  `device.id`: a random ID created on first launch and kept in the app's own storage — not a
  hardware or advertising ID; it resets on reinstall. The app's version and build become the
  release (`com.shop.app@2.3.0+41`) unless you pass `release`.

Telemetry is batched (every 5 s or 100 records), gzipped, retried with backoff, kept in memory
(capped) while offline, and sent when the app goes to the background. The SDK never throws into
your app; it prints one warning if the key is rejected (`debug: true` prints more).

## Options

| Option | Default | |
|---|---|---|
| `key` | — | Required. |
| `service`, `environment`, `release` | | `service.name`, `deployment.environment.name`, `service.version` |
| `endpoint` | `https://api.zharp.io/api/v1/otlp` | |
| `tracingOrigins` | `[]` | Hosts (`api.example.com`, `*.example.com`), origins, or `RegExp`s |
| `sampleRate` | `1.0` | Share of traces kept; errors and logs are always sent |
| `enabled` | `true` | e.g. `enabled: kReleaseMode` |
| `captureErrors` | `true` | |
| `reportSilentFlutterErrors` | `false` | |
| `sessionTimeout` | 30 min | |
| `debug` | `false` | |

## Develop

```bash
flutter pub get && flutter test
cd example && flutter run --dart-define=ZHARP_KEY=zpk_… --dart-define=ZHARP_ENDPOINT=http://10.0.2.2:3000/api/v1/otlp
```

The engine — OTLP encoding, batching, sessions, propagation — is the pure-Dart
[`zharp_core`](../zharp_core), tested with `dart test`.
