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
- **Logs** — `Zharp.log.debug/info/warn/error('message', {'key': value})`, tied to the current
  trace. What the app already logs and prints (`debugPrint`, `package:logging`, `print`, the
  `logger` package) is sent only when you turn logs on — see below.
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

## Logs from what the app prints

Off by default: unless you turn logs on, nothing the app logs or prints is sent. Errors, traces,
sessions and `Zharp.log` calls are sent either way. To send the app's logs:

```dart
await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', logs: true));
```

(or `--dart-define=ZHARP_LOGS=true`). Then you don't have to move your logging to `Zharp.log`:
what the app already logs is sent, each line tied to the trace, span, screen and session it was
written in, and still printed exactly as before:

| Written with | Sent |
|---|---|
| `debugPrint` (Flutter's own messages, many packages) | always |
| `package:logging` (`Logger('feed').warning(…)`) | always, with its own level and `log.logger`; SEVERE with an error is filed as an error |
| `print`, the `logger` package, `stdout`/`stderr` | inside `Zharp.guard` |

```dart
void main() => Zharp.guard(() async {
  await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', logs: true));
  runApp(const MyApp());
});
```

Dart gives no way to see `print` outside a zone, so without `Zharp.guard` it isn't sent. A line's
level is read from the line — a JSON `level`, `ERROR`, `[warn]`, `level=error`, `SEVERE`, the
`logger` package's `[E]` or emoji (its boxes become one record) — else info (warning on `stderr`).
A line is never sent twice: `Zharp.log` or a `package:logging` record that is also printed, and
Flutter's console dump of an error Zharp already reported, are sent once. Lines Zharp prints about
itself (`[Zharp] …`) are left out.

Not captured: `dart:developer`'s `log()` (it goes to the debugger, not through anything an app
can hook), native Android/iOS logs (logcat, `os_log`, `NSLog`), and other isolates' output.

With logs on, `captureOutput: false` (or `--dart-define=ZHARP_CAPTURE_OUTPUT=false`) sends only
`Zharp.log` calls.

## Logs only

Don't want tracing? Turn it off and keep logs, errors, users, sessions, screen names and tags:

```dart
await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', tracing: false));
```

With `tracing: false` no spans are created or sent: no screen-view spans, no HTTP spans from
`ZharpHttpClient` or `zharp_dio`, and no `traceparent`/`baggage` on outgoing requests (so
`tracingOrigins` has no effect). `Zharp.startSpan` still runs its callback. `ZharpNavigatorObserver`
still sets `app.screen.name` on logs and errors.

## Request and response bodies

Off by default. Turn on `captureBodies` to see what a request sent and what came back, under the
request in the trace (`ZharpHttpClient` and `zharp_dio`):

```dart
await Zharp.init(ZharpOptions(
  key: 'zpk_…',
  captureBodies: const CaptureBodies(),   // failed requests only; CaptureBodies.all() for every one
));
```

- `CaptureBodies()` keeps bodies for requests that failed (status 400 and above, or no response);
  `CaptureBodies.all()` for every request. Every request the app makes is covered, never Zharp's
  own; `urls` (written like `tracingOrigins`) narrows that.
- Text — JSON, forms, XML, plain text — is kept up to 32 KB (`maxSize`, up to 128 KB). Every field
  name stays. Files in uploads show as `[file photo.png · image/png · 240 KB]`, inline images as
  `[image/png · 24 KB]`, other bodies as `[binary · application/pdf · 1.2 MB]`. File contents are
  never sent.
- Values under secret-looking keys (`password`, `token`, `apiKey`, `authorization`, `cookie`,
  `card`, `cvv`, `ssn`, …) become `[Filtered]` in the app, before anything is sent; under a secret
  object, each value inside is hidden and its keys kept. Other personal data (names, emails) is
  sent as it is: add those keys to `redactKeys`.
- Your app reads its responses exactly as before; the span keeps the time the response arrived.

Whether or not bodies are on, secret-looking query values in URLs (`?token=`, `key`, `sig`,
`password`, …) are recorded as `[Filtered]`.

## Readable stack traces from obfuscated builds

Release builds made with `--obfuscate --split-debug-info` report stacks as addresses. Upload the
build's symbols and Zharp shows (and groups) those errors by your original functions, files and
lines:

```bash
flutter build apk --obfuscate --split-debug-info=build/symbols     # or appbundle, ipa, …
npx @zharp/cli dart-symbols upload build/symbols --app <application id>
```

`build/symbols` holds one `app.<os>-<arch>.symbols` file per architecture; upload them all, from
the same build you ship (each is matched to the app by the snapshot's build ID). The upload needs a
workspace API key with the `artifacts:write` scope in `ZHARP_AUTH_TOKEN` (a secret: CI only, never
in the app or the repo), and `ZHARP_URL` for a self-hosted Zharp.

Nothing changes in the app: zharp_flutter sends the stack exactly as the Dart VM writes it, with
its header (`build_id`, `os`/`arch`, `isolate_dso_base`), and adds `zharp.dart_build_id`,
`zharp.dart_os` and `zharp.dart_arch` to the error. Names of your own error classes are obfuscated
too (`exception.type` may read like `a5`); the frames are what the symbols restore.

## Flutter web

The same package works on the web. Wrap `main` in `Zharp.guard`: in a browser, an uncaught
error from a timer, a future or an event handler reaches Zharp only through the zone.

```dart
void main() => Zharp.guard(() async {
      await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-web'));
      runApp(const MyApp());
    });
```

A release build is minified JavaScript. Build it with source maps and upload them, and Zharp
shows (and groups) its errors by your Dart files and lines:

```bash
flutter build web --release --source-maps
npx @zharp/cli sourcemaps inject build/web
npx @zharp/cli sourcemaps upload build/web --app <application id> --delete-after
```

`inject` writes a debug ID into `main.dart.js` (deploy that file, not an earlier copy); `upload`
sends it with its map; `--delete-after` removes the `.map` so it isn't served. The same
`ZHARP_AUTH_TOKEN` as above. Error types read as you'd expect (`StateError`, `TypeError`, or your
class's name when its `toString()` starts with it) even though dart2js renames classes.

## Options

| Option | Default | |
|---|---|---|
| `key` | — | Required. |
| `service`, `environment`, `release` | | `service.name`, `deployment.environment.name`, `service.version` |
| `tracing` | `true` | `false` = logs only (see above) |
| `tracingOrigins` | `[]` | Hosts (`api.example.com`, `*.example.com`), origins, or `RegExp`s |
| `captureBodies` | off | `CaptureBodies()` or `CaptureBodies.all()` — see above |
| `sampleRate` | `1.0` | Share of traces kept; errors and logs are always sent |
| `enabled` | `true` | e.g. `enabled: kReleaseMode` |
| `captureErrors` | `true` | |
| `logs` | `false` (`ZHARP_LOGS`) | Send what the app logs and prints — see above |
| `captureOutput` | `true` (`ZHARP_CAPTURE_OUTPUT`) | With `logs` on: `debugPrint`, `package:logging`; `print`/`logger`/stdout inside `Zharp.guard` |
| `reportSilentFlutterErrors` | `false` | |
| `sessionTimeout` | 30 min | |
| `debug` | `false` | |

## Develop

```bash
flutter pub get && flutter test
cd example && flutter run --dart-define=ZHARP_KEY=zpk_…
```

The engine — OTLP encoding, batching, sessions, propagation — is the pure-Dart
[`zharp_core`](../zharp_core), tested with `dart test`.
