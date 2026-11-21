## 0.1.0 - 2026-11-17

## 0.1.1 - 2026-11-21

- Works with zharp_core 0.4.0.

- First release: `zharpMiddleware()` — a SERVER span per shelf (and dart_frog) request,
  continuing the caller's `traceparent` with its `baggage` session and user, failed on 5xx and
  thrown errors (reported), the request's ids stamped on every line printed while handling it;
  `setRequestRoute` names the route.
