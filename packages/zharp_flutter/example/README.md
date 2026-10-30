# zharp_flutter example

`lib/main.dart` — buttons for each feature. `lib/smoke.dart` — a hands-off run that opens a
screen, makes requests, logs, and reports a caught and an uncaught error.

```bash
flutter run --dart-define=ZHARP_KEY=zpk_… --dart-define=ZHARP_ENDPOINT=http://10.0.2.2:3000/api/v1/otlp
flutter run -t lib/smoke.dart --dart-define=ZHARP_KEY=zpk_… --dart-define=ZHARP_ENDPOINT=http://10.0.2.2:3000/api/v1/otlp
```

The key is passed at build time; don't commit one.
