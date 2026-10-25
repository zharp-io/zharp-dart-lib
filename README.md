# Zharp Dart SDKs

| Package | For |
|---|---|
| [`zharp_logs`](packages/zharp_logs) | Dart servers, CLIs, and any Dart code — including the web |
| [`zharp_logs_flutter`](packages/zharp_logs_flutter) | Flutter apps: adds automatic crash capture and lifecycle flushing |

Both send to the same place, in the same format, as the JavaScript SDK
[`@zharp/logs`](https://www.npmjs.com/package/@zharp/logs).

## Develop

```bash
cd packages/zharp_logs && dart pub get && dart test
cd packages/zharp_logs_flutter && flutter pub get && flutter test
```

`zharp_logs_flutter` uses the `zharp_logs` next to it through `pubspec_overrides.yaml`.

## Publish

`zharp_logs` first, then `zharp_logs_flutter` (it depends on the published `zharp_logs`):

```bash
cd packages/zharp_logs && dart pub publish
cd packages/zharp_logs_flutter && flutter pub publish
```
