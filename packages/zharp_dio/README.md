# zharp_dio

Traces [Dio](https://pub.dev/packages/dio) requests for Zharp Application Monitoring. Use it with
[`zharp_flutter`](../zharp_flutter).

```bash
flutter pub add zharp_flutter zharp_dio
```

```dart
final dio = Dio()..interceptors.add(ZharpDioInterceptor());
```

Each request becomes a CLIENT span (`http.request.method`, `url.full`, `http.response.status_code`)
in the trace of the screen or span it was made from. Requests to the hosts in
`ZharpOptions.tracingOrigins` carry `traceparent` and `baggage` (`session.id`, `enduser.id`), so
your back end's spans join the same trace. Other hosts get no extra headers.

With `ZharpOptions.captureBodies` on, failed requests (or every request) also carry what was
sent and what came back: `data` as JSON or text, a `FormData` upload as its fields with each file
described (`[file photo.png · image/png · 240 KB]`), bytes decoded when they are text, a streamed
body described. Secret-looking values are `[Filtered]` before anything leaves the app.

It is a separate package so apps that don't use Dio don't download it.
