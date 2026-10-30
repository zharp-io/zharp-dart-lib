# Zharp Dart SDKs

| Package | For |
|---|---|
| [`zharp_logs`](packages/zharp_logs) | Dart servers, CLIs, and any Dart code — including the web |
| [`zharp_logs_flutter`](packages/zharp_logs_flutter) | Flutter apps: adds automatic crash capture and lifecycle flushing |
| [`zharp_flutter`](packages/zharp_flutter) | **Application Monitoring** for Flutter: errors, logs, screen views, traced HTTP, sessions (OTLP) |
| [`zharp_dio`](packages/zharp_dio) | Application Monitoring: traces Dio requests (add with `zharp_flutter`) |
| [`zharp_core`](packages/zharp_core) | The pure-Dart engine behind `zharp_flutter` and `zharp_dio` |

Both send to the same place, in the same format, as the JavaScript SDK
[`@zharp/logs`](https://www.npmjs.com/package/@zharp/logs).

## Develop

```bash
cd packages/zharp_logs && dart pub get && dart test
cd packages/zharp_logs_flutter && flutter pub get && flutter test
cd packages/zharp_core && dart pub get && dart test
cd packages/zharp_dio && dart pub get && dart test
cd packages/zharp_flutter && flutter pub get && flutter test
```

`zharp_flutter` and `zharp_dio` use the `zharp_core` next to them through `pubspec_overrides.yaml`;
publish `zharp_core` first.

`zharp_logs_flutter` uses the `zharp_logs` next to it through `pubspec_overrides.yaml`.

## Publish

`zharp_logs` first, then `zharp_logs_flutter` (it depends on the published `zharp_logs`):

```bash
cd packages/zharp_logs && dart pub publish
cd packages/zharp_logs_flutter && flutter pub publish
```
