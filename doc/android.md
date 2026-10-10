# Android integration

Require Android API 21+, JDK 17 for building, and the pinned Gradle wrapper. The source uses Java 11 bytecode. Select `trasivo` for task management and HTTP transfers; add `trasivo-storage` for MediaStore or document destinations and `trasivo-ui` only for the bundled overlay. During source development, use a Gradle composite build to substitute the selected coordinates with their corresponding projects. Consumer generation is provided by [Integrated Plugins](https://github.com/sandroxy/integrated-plugins). No Maven release is currently declared.

Retain an application-scoped `TransferCenter` and `OkHttpClient`. The HTTP client remains host-owned; configure timeouts, authentication and network policy there. Supply fresh requests on every retry.

```java
TransferCenter center = new TransferCenter();
String id = center.enqueue(
    new TransferTask.Request("photo.jpg", TransferTask.Direction.DOWNLOAD),
    HttpTransfers.download(client,
        () -> new Request.Builder().url(downloadUrl).build(),
        application.getCacheDir(),
        new MediaDestination(application, "photo.jpg", "image/jpeg")));
```

Import core types from `com.sandrox.trasivo`, storage from `com.sandrox.trasivo.storage`, and HTTP types from `okhttp3`. The download above does not use the UI module. Ask for any required destination permission before enqueueing it.

`HttpTransfers.upload(client, requests, handler)` requires a repeatable, non-duplex body. For multipart form requests, use OkHttp's `MultipartBody` with a file-backed `RequestBody`. The response handler receives status, headers and bounded body bytes. Parse and validate the application's protocol there; return small safe result metadata or throw on rejection. Return no raw server response in task history.

## Destinations and permissions

- `HttpTransfers.file(file)` writes a new app-owned local file without overwriting another file. Its parent directory must exist. Failures remove only the newly created target.
- `MediaDestination(context, filename, mimeType)` saves images or videos. Android 10+ inserts an owned MediaStore item without broad media-read or all-files permission. Android 6–9 needs host-requested `WRITE_EXTERNAL_STORAGE` before enqueueing; the module manifest limits the permission to API 28.
- `DocumentDestination(resolver, uri)` writes to a **new** URI returned by the host's `ACTION_CREATE_DOCUMENT`. It must not be given an existing valuable document. A provider failure can leave partial data; the host owns the URI and may retry or explicitly remove the incomplete document. Provider closure is the success boundary, not confirmation of a remote provider's cloud synchronization.

The host initiates permission prompts and file pickers. The UI never requests storage or overlay permission. Select MIME types from trusted metadata; do not infer image/video type from an arbitrary signed URL.

## Host-owned presentation

Save the ID returned by `enqueue` in the host's resource model. When a screen is recreated, bind to that ID instead of enqueueing again. A resource card and the bundled panel may observe and control the same center concurrently. Each observer receives an initial snapshot and subsequent changes.

```java
// Members of a host screen; center and the resource's task ID outlive it.
private TransferCenter.Subscription subscription;

void bind(TransferCenter center, String taskId) {
    stopObserving();
    subscription = center.observe(tasks -> {
        TransferTask selected = null;
        for (TransferTask task : tasks) {
            if (task.id.equals(taskId)) { selected = task; break; }
        }
        if (selected == null) {
            renderUnavailable(); // Removed, evicted, or from a previous process.
            return;
        }
        renderTask(selected);
        retryButton.setEnabled(selected.canRetry());
        cancelButton.setEnabled(selected.canCancel());
    });
    retryButton.setOnClickListener(view -> {
        if (!center.retry(taskId)) renderActionUnavailable();
    });
    cancelButton.setOnClickListener(view -> {
        if (!center.cancel(taskId)) renderActionUnavailable();
    });
}

void stopObserving() {
    if (subscription != null) { subscription.close(); subscription = null; }
}
```

The `render…` functions and buttons belong to the host. Call `stopObserving` when the screen's observation lifetime ends, such as `Activity.onDestroy`. `renderUnavailable` must clear stale progress and disable task actions; absence is not success. `renderTask` uses the state as the authority: show indeterminate progress for an unknown total, a separate saving/validation state for `FINALIZING`, and success only for `SUCCEEDED`. A full byte count alone is insufficient. An operation can become unavailable between rendering a button and tapping it, so handle a false action result.

Use one screen-level subscription to route snapshots by task ID when rendering multiple resources. Closing a subscription does not cancel work. Retry preserves the task ID and changes the attempt ID; removal or history eviction ends that record's observation. Resource identity, duplicate-start prevention, and any durable business result belong to the host. In-process snapshots are not a durable resource database.

## Optional UI configuration

Add `trasivo-ui` and import `com.sandrox.trasivo.ui` only when using the bundled presentation. There is no core UI-mode flag: without a `TransferOverlay`, transfers run with host-owned presentation alone.

```java
TransferUIConfiguration.Theme theme =
    new TransferUIConfiguration.Theme().withPrimary(brandColor);
TransferUIConfiguration config = new TransferUIConfiguration(
    TransferUIConfiguration.Language.JAPANESE, theme, null);
TransferOverlay overlay = new TransferOverlay(activity, overlayParent, center, config);
overlay.showPanel();
overlay.updateConfiguration(new TransferUIConfiguration()); // defaults, also updates an open panel
// Activity.onDestroy:
overlay.close();
```

Create a new overlay with the same center to reattach it. Closing or attaching the overlay does not enqueue, cancel, retry, or remove tasks. Host resource views can remain subscribed throughout. The bundled UI is an independently usable, maintained presentation module; its theme and language settings do not configure host-owned views.

The full theme constructor accepts primary, background, surface, text, muted text, border, success and danger ARGB colors. Passing null for configuration, language or theme uses the documented default. A null title uses the localized built-in title. For dark mode, resolve host colors from its current resources and apply a new configuration after the host appearance changes. Default colors deliberately remain fixed.

Use `observe` for a host-owned start message or completion notice and close the returned subscription with its owner. The core does not display toasts. Do not equate transferred bytes with save success; inspect the state and result.
