## Unreleased

- First release: `zharpMiddleware()` — a SERVER span per shelf (and dart_frog) request,
  continuing the caller's `traceparent` with its `baggage` session and user, failed on 5xx and
  thrown errors (reported), the request's ids stamped on every line printed while handling it;
  `setRequestRoute` names the route.
