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

It is a separate package so apps that don't use Dio don't download it.
