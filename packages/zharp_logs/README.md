# zharp_logs

Send your Dart app's logs to [Zharp](https://zharp.io). Works on servers, CLIs, and anywhere Dart
runs — including the web. Building a Flutter app? Use
[`zharp_logs_flutter`](https://pub.dev/packages/zharp_logs_flutter): it adds automatic crash capture.

Full documentation: [zharp.io/docs/sdks/logs](https://zharp.io/docs/sdks/logs)

---

## 1. Install

```bash
dart pub add zharp_logs
```

## 2. Get an API key

1. In Zharp, open **Integrations & API** and choose **Main API keys**.
2. Click **Create API key**, give it a name, and tick **Ingest only**. That key can send logs but
   can't read anything, so it's safe in a server's environment or an app.
3. Click **Create key** and copy the key — it's shown only once.

<p>
  <img src="https://www.zharp.io/images/docs/api-key-create.png" alt="Create API key, with Ingest only ticked" width="48%">
  <img src="https://www.zharp.io/images/docs/api-key-created.png" alt="The new key, shown once with a Copy button" width="48%">
</p>

## 3. Start it

Call `init()` once, as early as possible. Give it your key in code, or let it read the key from
the environment — either works.

**In code:**

```dart
import 'package:zharp_logs/zharp_logs.dart';

void main() {
  ZharpLogger.init(apiKey: 'your-ingest-only-key', service: 'checkout-api');
}
```

**From the environment** — set the variables and call `init()` with nothing:

```bash
ZHARP_API_KEY=your-ingest-only-key
ZHARP_SERVICE=checkout-api
```

```dart
ZharpLogger.init();
```

The same settings can be compiled in with `--dart-define` (the only way for a web build):

```bash
dart compile exe bin/server.dart --define=ZHARP_API_KEY=your-ingest-only-key --define=ZHARP_SERVICE=checkout-api
```

You can mix them: what you pass to `init()` is used, and anything you leave out is read from
`--dart-define`, then the environment. When run with `dart run`, `service` defaults to the `name` in
your pubspec.yaml.

When it starts, it prints one line so you know it's working:

```
[Zharp] Logging active — service "checkout-api", environment "production"
```

With no API key anywhere it prints how to give it one and sends nothing.

### Capture crashes (servers and CLIs)

Run your app inside `ZharpLogger.guard`. An uncaught error is sent with its stack, then printed
and the process ends with exit code 1 — as it would have without Zharp:

```dart
void main() {
  ZharpLogger.init();
  ZharpLogger.guard(() async {
    await serve();
  });
}
```

Pass `exitOnError: false` to keep running after an uncaught error instead.

## 4. Log

```dart
ZharpLogger.info('User signed in', {'userId': 42});
ZharpLogger.warn('Slow network detected', {'latencyMs': 3200});
ZharpLogger.error('Payment failed', {'orderId': 99, 'reason': 'insufficient_funds'});
```

`debug` and `fatal` are there too. The map is optional and is kept with the log. A caught error
can be logged as it is — its stack goes with it:

```dart
try {
  await charge(order);
} catch (e) {
  ZharpLogger.error(e);                               // message, type and stack
  ZharpLogger.error('Payment failed', {'err': e});    // or with your own message
}
```

For the exact stack of an `Exception` (which, unlike an `Error`, doesn't carry one), pass the one
`catch` gives you:

```dart
try {
  await charge(order);
} catch (e, stack) {
  ZharpLogger.captureException(e, stack, metadata: {'orderId': order.id});
}
```

Logs are sent in batches every 5 seconds; `error` and `fatal` go at once. A short script that
should exit straight away can end with `await ZharpLogger.close();`, which sends what's left and
stops.

## 5. See your logs

Sign in at [zharp.io](https://zharp.io/login), open **Logs**, and pick your service in the
service dropdown.

![The Logs page on zharp.io](https://www.zharp.io/images/docs/logs-dashboard.png)

---

## Options

| Option | Environment variable / `--dart-define` | Default |
|---|---|---|
| `apiKey` | `ZHARP_API_KEY` | — |
| `service` | `ZHARP_SERVICE`, then `OTEL_SERVICE_NAME` | the `name` in your pubspec.yaml (with `dart run`), else `unknown-service` |
| `environment` | `ZHARP_ENV` | none |
| `appVersion` | `ZHARP_VERSION` | none |
| `source` | `ZHARP_SOURCE` | none |
| `capturePrint` | `ZHARP_CAPTURE_PRINT` | off — see below |
| `flushInterval` | — | 5 seconds |
| `maxBatchSize` | — | `50` |
| `endpoint` | `ZHARP_ENDPOINT` | `https://api.zharp.io/api/v1` |

An option passed to `init()` wins. `ZHARP_DISABLED=true` turns the SDK off.

## What's sent automatically

- **Uncaught errors inside `guard`**, as `error` logs with their stack.
- **What your app prints — only if you ask.** `capturePrint: true` also sends what code inside
  `guard` prints, as `info` logs; the console still prints as before. Where the
  [Zharp agent](https://zharp.io/docs/agent/setup) already collects your output, leave it off, or
  every line arrives twice.

Every log also carries a session ID (the same for one run of your app) and where it ran: host,
platform, OS and Dart version. Add your own fields to every log with
`ZharpLogger.setContext({'userId': user.id})`.

## Already using `package:logging`?

Forward its records:

```dart
import 'package:logging/logging.dart';
import 'package:zharp_logs/zharp_logs.dart';

LogLevel _levelOf(Level level) => level >= Level.SHOUT
    ? LogLevel.fatal
    : level >= Level.SEVERE
        ? LogLevel.error
        : level >= Level.WARNING
            ? LogLevel.warn
            : level >= Level.INFO
                ? LogLevel.info
                : LogLevel.debug;

void forwardToZharp() {
  Logger.root.onRecord.listen((record) {
    ZharpLogger.log(_levelOf(record.level), record.message, metadata: {
      'logger': record.loggerName,
      if (record.error != null) 'error': record.error.toString(),
      if (record.stackTrace != null) 'stack': record.stackTrace.toString(),
    });
  });
}
```

## License

MIT © [Zharp](https://zharp.io)
