# Trasivo

Native upload and download tasks with an optional floating indicator and transfer panel.

[简体中文](README.zh-CN.md) · [Contract](doc/contract.md) · [Android](doc/android.md) · [iOS](doc/ios.md) · [Building](BUILDING.md)

Trasivo separates task ownership, HTTP transport, system storage and presentation. Applications provide requests and decide what a successful upload response means. The core does not depend on a business API, account model, media viewer or JavaScript runtime.

Hosts can draw progress and actions beside each resource, use the optional floating indicator and panel, or display both together. All presentations observe and control the same task ID. Attaching or closing a view does not change the task's lifetime. The optional UI is maintained as a separate module and is included only when needed.

| Platform | Core | System storage | Optional UI |
| --- | --- | --- | --- |
| Android 5.0+ | `trasivo`, OkHttp | `trasivo-storage`, MediaStore and document URIs | `trasivo-ui`, Android Views |
| iOS 13+ | `Trasivo`, URLSession | `TrasivoStorage`, Photos | `TrasivoUI`, UIKit |

The center owns a bounded concurrent queue and in-process history. It reports transferred bytes, finalization, success, failure and cancellation. Failed or canceled tasks can retry from the beginning. Removing a history entry does not remove the saved file.

The UI accepts host colors, a title and an explicit language: Simplified Chinese, Traditional Chinese, English or Japanese. Without overrides it uses the built-in teal palette and **Simplified Chinese**, independently of the device language. Configuration can change while the UI is attached. The overlay stays inside the application and requires no system overlay permission.

Downloads succeed only after their destination finishes saving. Uploads succeed only after the application's response validator accepts the response. Streaming avoids loading a whole media file into memory; an unknown total remains unknown.

Task history and execution are not durable across process termination. There is no pause, byte-range recovery, resumable multipart protocol or guaranteed background execution. HTTP `multipart/form-data` support is request encoding, not resumable uploading. See the [contract](doc/contract.md) before integrating.

This repository provides source packages; `0.1.0` is source metadata, not a claim of a published Maven or Swift release. Native development consumers live in [Integrated Plugins](https://github.com/sandroxy/integrated-plugins). React Native and other framework adapters are not included.

Licensed under [Apache-2.0](LICENSE). Dependencies and provenance are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
