# Zharp Dart SDKs

| Package | For |
|---|---|
| [`zharp_flutter`](packages/zharp_flutter) | **Application Monitoring** for Flutter: errors, logs, screen views, traced HTTP, sessions (OTLP) |
| [`zharp_dio`](packages/zharp_dio) | Application Monitoring: traces Dio requests (add with `zharp_flutter`) |
| [`zharp_shelf`](packages/zharp_shelf) | Dart servers on shelf or dart_frog: a SERVER span per request, its ids on every line printed |
| [`zharp_core`](packages/zharp_core) | The pure-Dart engine behind `zharp_flutter` and `zharp_dio`; works on its own in Dart servers, CLIs and the web |

## Logs only

Every package can run without tracing — logs, errors, users, sessions and tags are still sent; no
spans, and no `traceparent`/`baggage` on outgoing requests:

```dart
await Zharp.init(ZharpOptions(key: 'zpk_…', service: 'shop-app', tracing: false));
```

## Develop

```bash
cd packages/zharp_core && dart pub get && dart test
cd packages/zharp_dio && dart pub get && dart test
cd packages/zharp_shelf && dart pub get && dart test
cd packages/zharp_flutter && flutter pub get && flutter test
```

`zharp_flutter`, `zharp_dio` and `zharp_shelf` use the `zharp_core` next to them through `pubspec_overrides.yaml`;
publish `zharp_core` first.
