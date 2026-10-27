## 0.1.1

- **A rejected API key stops the sending.** When Zharp answers 401 or 403 — a deleted or revoked
  key — the SDK (zharp_logs 0.1.3) prints one line (`[Zharp] Zharp rejected this API key (HTTP 401) — logs are not
  being sent. Check ZHARP_API_KEY.`) and stops sending instead of having every batch refused.
  Batches are dropped, not kept, so memory stays bounded. One batch is tried again an hour later;
  if the key is accepted, sending resumes and says so once.

## 0.1.0

- First release: `ZharpFlutter.init()` — Flutter framework and uncaught async errors sent
  automatically, queued logs sent when the app goes to the background, optional `debugPrint`
  capture.
