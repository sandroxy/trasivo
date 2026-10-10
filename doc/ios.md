# iOS integration

Add this source directory as a local Swift package. Select `Trasivo` for task management and HTTP transfers, `TrasivoStorage` when saving to Photos, and `TrasivoUI` only for the bundled overlay. The minimum deployment target is iOS 13. No remote versioned package release is currently declared.

Retain an application-scoped center independently of presentation controllers:

```swift
import Trasivo
import TrasivoStorage

let center = try TransferCenter()
let destination = try PhotoLibraryDestination(media: .image, filename: "photo.jpg")
let operation = HTTPTransfers.download(
    request: { URLRequest(url: downloadURL) }, destination: destination)
let taskID = center.enqueue(try TransferRequest(title: "photo.jpg", direction: .download), operation: operation)
```

Ask for photo authorization before enqueueing this example. `PhotoLibraryAccess.request` requires `NSPhotoLibraryAddUsageDescription`; supporting iOS 13 also requires `NSPhotoLibraryUsageDescription`. Provide meaningful localized usage descriptions in the host. iOS 14+ requests add-only access. The destination reports success only after Photos commits the resource. Use `.video` for video files.

Image types are read from the file contents using Image I/O; the original bytes are passed to Photos without re-encoding. For videos, `filename` must have the correct movie extension, such as `.mp4`, `.mov`, or `.m4v`. The destination supplies an explicit resource type and stages a temporary hard link with that type's extension: setting `originalFilename` or the type alone does not make an unknown file URL extension acceptable to Photos. The link avoids another full media copy before Photos imports it and is removed after Photos finishes. Direct callers of `save` must supply an app-owned local file in a writable directory on a volume that supports hard links, as the HTTP downloader does; the source path and bytes remain unchanged.

Photos still validates the media before committing it. Unrecognized media types, preparation failures, and failed imports report `destination_failed`; native errors record only their domain and code in the `io.github.sandroxy.trasivo` / `Photos` system log, without filenames, paths, or error payloads.

`FileDestination(url:)` writes a new file in app-owned local storage. Its parent must exist; the destination volume must support hard links, as normal app containers do. It stages the copy alongside the destination, then publishes without replacing an existing path. Export a saved app file with the host's document picker or share sheet when the user wants a Files location. A custom `DownloadDestination` may implement another destination, but must complete only after that save finishes.

## Uploads

`HTTPTransfers.upload(request:file:validateResponse:)` uploads a stable file with an explicit POST/PUT or other body-supporting method. Do not set `httpBody` or `httpBodyStream`; the file provider supplies the body. Both providers are evaluated anew per retry. The response validator must accept the business response before returning safe metadata. Throw `TransferFailure("response_rejected")` when HTTP 200 contains an application failure.

For `multipart/form-data`, construct `MultipartBody(file:field:filename:mimeType:fields:)` off the main thread, set its `contentType` on the request, and return `body.fileURL` from the file provider. **Capture and retain the body object**, not just its URL: its temporary encoding file is removed on deallocation. This encoder does not implement resumable multipart upload. Keep the source stable for as long as retry is available.

URLSession uses ephemeral foreground sessions and platform TLS/ATS policy. Background transfer sessions, custom trust exceptions and automatic persistence are not enabled. Authentication goes in fresh request headers. Auth refresh and protocol-specific reconciliation belong to the host.

## Host-owned presentation

Store the returned task ID in the host's resource model, independently of the view controller. Reopening a resource binds to the existing ID; it must not enqueue another transfer. A host resource view and the bundled panel can observe and control the same center concurrently.

```swift
// Members of a host view controller; center is retained by the application.
private var subscription: TransferSubscription?
private var taskID: String?

func bind(center: TransferCenter, taskID: String) {
    subscription?.cancel()
    self.taskID = taskID
    subscription = center.observe { [weak self] tasks in
        guard let self = self else { return }
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            self.renderUnavailable()
            return
        }
        self.renderTask(task)
        self.retryButton.isEnabled = task.canRetry
        self.cancelButton.isEnabled = task.canCancel
    }
}

func retry(using center: TransferCenter) {
    guard let id = taskID, center.retry(id) else { renderActionUnavailable(); return }
}

func cancel(using center: TransferCenter) {
    guard let id = taskID, center.cancel(id) else { renderActionUnavailable(); return }
}

func stopObserving() {
    subscription?.cancel()
    subscription = nil
}
```

The `render…` methods and buttons belong to the host. Bind the buttons to these actions, and call `stopObserving` when the screen's observation lifetime ends. Observing delivers an initial snapshot followed by changes. Use weak captures to avoid retaining the view controller; retain the subscription until it is no longer needed.

`renderUnavailable` clears stale progress and disables actions after record removal, eviction, or a process restart. It must not infer success or automatically restart a transfer. `renderTask` uses states to distinguish transport progress, `.finalizing` (saving or validation), and `.succeeded`. Unknown totals need indeterminate progress; a full byte count does not prove successful saving. An action may return false if the task changed since its button was rendered.

For multiple resource views, route snapshots by task ID from one screen-level observer. Retry keeps that ID and changes the attempt ID. The host owns resource identity, duplicate-start prevention, and any durable business result; the task center retains only in-process history.

## Optional UI configuration

Add the `TrasivoUI` product only for this presentation:

```swift
import TrasivoUI

let config = TransferUIConfiguration(language: .traditionalChinese,
    theme: TransferTheme(primary: brandColor))
let overlay = TransferOverlay(center: center, parent: view,
    presenter: self, configuration: config)
overlay.showPanel()
overlay.updateConfiguration(TransferUIConfiguration())
```

Retain the overlay and invoke its methods on the main thread. It owns an application-contained draggable button and a UIKit sheet. Detach with `close()` when its presentation lifetime ends. The task center and active work continue independently.

No core UI-mode flag is required. Without an overlay, host-owned views can use the core alone. Reattach by creating a new overlay with the same center; this does not enqueue, cancel, retry, or remove tasks. The bundled UI is an independently usable, maintained presentation module. Its theme and language do not configure host-owned views.

Themes accept primary, background, surface, text, muted text, border, success and danger UIColors. The default language is Simplified Chinese. The title defaults to the localized built-in title. Host-provided dynamic UIColors are supported; reapply configuration after a trait change so layer-backed ring colors are resolved again. Changes also update a currently presented panel.

Retain observation subscriptions; deallocation unsubscribes. The default observer queue is main. Use task states to drive host notifications; network bytes alone do not prove successful saving or server acceptance.
