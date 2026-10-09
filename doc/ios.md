# iOS integration

Add this source directory as a local Swift package and select the required products: `Trasivo`, `TrasivoStorage`, `TrasivoUI`. The minimum deployment target is iOS 13. No remote versioned package release is currently declared.

Retain an application-scoped center independently of presentation controllers:

```swift
import Trasivo
import TrasivoStorage
import TrasivoUI

let center = try TransferCenter()
let destination = try PhotoLibraryDestination(media: .image, filename: "photo.jpg")
let operation = HTTPTransfers.download(
    request: { URLRequest(url: downloadURL) }, destination: destination)
center.enqueue(try TransferRequest(title: "photo.jpg", direction: .download), operation: operation)
```

Ask for photo authorization before enqueueing this example. `PhotoLibraryAccess.request` requires `NSPhotoLibraryAddUsageDescription`; supporting iOS 13 also requires `NSPhotoLibraryUsageDescription`. Provide meaningful localized usage descriptions in the host. iOS 14+ requests add-only access. The destination reports success only after Photos commits the resource. Use `.video` for video files.

`FileDestination(url:)` writes a new file in app-owned local storage. Its parent must exist; the destination volume must support hard links, as normal app containers do. It stages the copy alongside the destination, then publishes without replacing an existing path. Export a saved app file with the host's document picker or share sheet when the user wants a Files location. A custom `DownloadDestination` may implement another destination, but must complete only after that save finishes.

## Uploads

`HTTPTransfers.upload(request:file:validateResponse:)` uploads a stable file with an explicit POST/PUT or other body-supporting method. Do not set `httpBody` or `httpBodyStream`; the file provider supplies the body. Both providers are evaluated anew per retry. The response validator must accept the business response before returning safe metadata. Throw `TransferFailure("response_rejected")` when HTTP 200 contains an application failure.

For `multipart/form-data`, construct `MultipartBody(file:field:filename:mimeType:fields:)` off the main thread, set its `contentType` on the request, and return `body.fileURL` from the file provider. **Capture and retain the body object**, not just its URL: its temporary encoding file is removed on deallocation. This encoder does not implement resumable multipart upload. Keep the source stable for as long as retry is available.

URLSession uses ephemeral foreground sessions and platform TLS/ATS policy. Background transfer sessions, custom trust exceptions and automatic persistence are not enabled. Authentication goes in fresh request headers. Auth refresh and protocol-specific reconciliation belong to the host.

## UI configuration

```swift
let config = TransferUIConfiguration(language: .traditionalChinese,
    theme: TransferTheme(primary: brandColor))
let overlay = TransferOverlay(center: center, parent: view,
    presenter: self, configuration: config)
overlay.showPanel()
overlay.updateConfiguration(TransferUIConfiguration())
```

Retain the overlay and invoke its methods on the main thread. It owns an application-contained draggable button and a UIKit sheet. Detach with `close()` when its presentation lifetime ends. The task center and active work continue independently.

Themes accept primary, background, surface, text, muted text, border, success and danger UIColors. The default language is Simplified Chinese. The title defaults to the localized built-in title. Host-provided dynamic UIColors are supported; reapply configuration after a trait change so layer-backed ring colors are resolved again. Changes also update a currently presented panel.

Retain observation subscriptions; deallocation unsubscribes. The default observer queue is main. Use task states to drive host notifications; network bytes alone do not prove successful saving or server acceptance.
