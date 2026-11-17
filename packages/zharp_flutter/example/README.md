# zharp_flutter example

`lib/main.dart` — buttons for each feature. `lib/smoke.dart` — a hands-off run that opens a
screen, makes requests, logs, and reports a caught and an uncaught error.

```bash
flutter run --dart-define=ZHARP_KEY=zpk_…
flutter run -t lib/smoke.dart --dart-define=ZHARP_KEY=zpk_…
```

The key is passed at build time; don't commit one.
