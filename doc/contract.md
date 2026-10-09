# Transfer contract

## Ownership

Create one `TransferCenter` for the intended application/account lifetime and retain it independently of screens. An overlay or subscription only observes the center. Closing either does not stop work. Before switching accounts, the host must detach the old UI and explicitly cancel eligible tasks. Finalizing tasks must settle before their account resources are discarded.

Operations and request providers are retained for retry until their record is removed or evicted. They must not capture an Activity or view controller. The host owns credentials, endpoint selection, token refresh, idempotency, stable upload source files and permitted result metadata. Do not include secrets in task titles, error codes or result dictionaries. There is no disk task database or network logging in the core.

## State and attempts

`queued → running → finalizing → succeeded` is the normal built-in transfer path. An error produces `failed`. `queued` and `running` may be canceled. `finalizing` covers an irreversible destination write or application response validation and rejects cancellation and retry. Custom operations may finish directly when no separate commit is needed.

Retry is allowed only for `failed` and `canceled`. It retains the task ID, replaces the attempt ID, increments the attempt count, resets bytes and results, and evaluates the operation again. It downloads or uploads from zero. Old attempt progress and completions cannot change the new attempt. A terminal result accepts no further completion.

Default concurrency is 3; up to 200 terminal records are retained, evicting the oldest inserted terminal records first. Active tasks are never evicted. `remove` accepts terminal records only and never removes destination data. Hosts should limit how many tasks they enqueue and remove unneeded records to release retained upload sources.

Cancellation is best effort at the transport boundary. A server may already have received an upload before cancellation or a lost response. Retrying a non-idempotent upload can create a duplicate: the application must supply an idempotency key or reconcile its own protocol. Cancellation cannot undo a completed server action.

## Progress and success

`completedBytes` is nonnegative; `totalBytes == -1` means unknown. Progress is monotonic within an attempt and notifications are throttled to roughly 150 ms; transitions always emit. An HTTP library's internal replay may temporarily provide lower byte counts, which the center ignores. Bytes describe local transport progress, not server acceptance or destination persistence.

Built-in downloads require a fresh GET without a Range header and a final HTTP 200 response. Temporary files are removed after normal completion, failure or cancellation. The destination must consume the temporary file before returning (Android) or completing (iOS). Success requires destination commitment. A crash can leave temporary files; hosts may remove abandoned Trasivo temporary files at a later cold start before starting new tasks.

Built-in uploads require a repeatable body. Android accepts OkHttp bodies; use file-backed bodies for large uploads. iOS uses file-backed URLSession uploads and optionally the streaming `MultipartBody` encoder. Response bodies are limited to 1 MiB. A 2xx response is then passed to the required host validator; a rejected response fails the task even when HTTP returned 200. Work following upload, such as message publishing, belongs to a host-defined operation if it must share the same success boundary.

The bundled local-file destinations refuse an existing target. Android MediaStore owns its inserted row and removes it on failure; modern Android publishes it only after copying. Document providers and Photos have different commit semantics; see platform guides. There is no cross-process exactly-once save guarantee.

## Custom operations and observation

Implement `TransferOperation.start` as a repeatable asynchronous operation. Return a quick, nonthrowing cancellation handle; report completion exactly once. Do not block a cancellation callback. Report semantic error codes rather than exception text or server bodies. Call `beginFinalization` immediately before the noncancelable commit and always eventually report its outcome. A custom destination that never completes keeps its task and concurrency slot occupied.

The center serializes its state. Built-in transport, destination and validator callbacks run off the UI thread. Default observations arrive on the main thread; an injected callback executor/queue must be serial, preserve submission order and remain available throughout the center's lifetime. Subscriptions suppress callbacks not yet delivered after closing; a callback already executing may finish. Android injected worker executors must also remain available; rejection fails the affected attempt.

Call UI attachment, presentation, configuration updates and detachment on the main thread. Retain the iOS overlay. Close the Android overlay when its Activity is destroyed, and attach a new one to the same center after recreation. The center does not persist across application death and uses ordinary foreground HTTP sessions; mobile background limits still apply.

## Modules

The core exposes snapshots and operations without importing the UI or Photos/MediaStore adapters. Optional UI imports only the core. Optional storage imports only the core and system APIs. A future framework adapter can forward the public contract without relocating task ownership into JavaScript. Product protocol and resumable transport extensions require their own verified contracts; the current UI does not advertise unsupported controls.
