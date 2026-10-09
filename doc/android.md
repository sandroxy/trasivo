# Android integration

Require Android API 21+, JDK 17 for building, and the pinned Gradle wrapper. The source uses Java 11 bytecode. During source development, use a Gradle composite build and substitute the three explicit coordinates with their corresponding projects. Consumer generation is provided by [Integrated Plugins](https://github.com/sandroxy/integrated-plugins). No Maven release is currently declared.

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

Import core types from `com.sandrox.trasivo`, storage from `com.sandrox.trasivo.storage`, UI from `com.sandrox.trasivo.ui`, and HTTP types from `okhttp3`.

`HttpTransfers.upload(client, requests, handler)` requires a repeatable, non-duplex body. For multipart form requests, use OkHttp's `MultipartBody` with a file-backed `RequestBody`. The response handler receives status, headers and bounded body bytes. Parse and validate the application's protocol there; return small safe result metadata or throw on rejection. Return no raw server response in task history.

## Destinations and permissions

- `HttpTransfers.file(file)` writes a new app-owned local file without overwriting another file. Its parent directory must exist. Failures remove only the newly created target.
- `MediaDestination(context, filename, mimeType)` saves images or videos. Android 10+ inserts an owned MediaStore item without broad media-read or all-files permission. Android 6–9 needs host-requested `WRITE_EXTERNAL_STORAGE` before enqueueing; the module manifest limits the permission to API 28.
- `DocumentDestination(resolver, uri)` writes to a **new** URI returned by the host's `ACTION_CREATE_DOCUMENT`. It must not be given an existing valuable document. A provider failure can leave partial data; the host owns the URI and may retry or explicitly remove the incomplete document. Provider closure is the success boundary, not confirmation of a remote provider's cloud synchronization.

The host initiates permission prompts and file pickers. The UI never requests storage or overlay permission. Select MIME types from trusted metadata; do not infer image/video type from an arbitrary signed URL.

## UI configuration

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

The full theme constructor accepts primary, background, surface, text, muted text, border, success and danger ARGB colors. Passing null for configuration, language or theme uses the documented default. A null title uses the localized built-in title. For dark mode, resolve host colors from its current resources and apply a new configuration after the host appearance changes. Default colors deliberately remain fixed.

Use `observe` for a host-owned start message or completion notice and close the returned subscription with its owner. The core does not display toasts. Do not equate transferred bytes with save success; inspect the state and result.
