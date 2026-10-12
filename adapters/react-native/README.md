# React Native

The adapter exposes Trasivo's native center to React Native. Requests, authentication and response interpretation remain in the host. The native core, storage and UI modules have no dependency on React Native or Expo.

The integration baseline is React Native 0.81.5, React 19.1, Android API 24+ and iOS 15.1+. New Architecture Codegen and legacy module entry points share the same native coordinator. Expo is optional; the config plugin supports Expo 54. A native development build is required; Expo Go does not contain Trasivo.

This source adapter is not an npm release. Its package is private until a distribution contract is established. Use the isolated source consumer in [Integrated Plugins](https://github.com/sandroxy/integrated-plugins); do not reference its generated workspace from a production application.

## Native inputs

Android consumes the three native AARs in `android/libs/` plus the transport dependencies pinned in the adapter build. iOS consumes three local source pods with the same module names as the Swift package. The development preparer copies canonical Swift sources into ignored `ios/Core/<module>/` inputs and places a license alongside the adapter. Edit the canonical product sources, not those copies. The RN bridge does not require a second iOS framework packaging pipeline.

For bare RN, after preparing the package's native inputs, autolinking installs the bridge. The application's Podfile must also declare the native source pods inside its application target, before `use_native_modules!`:

```ruby
require File.join(File.dirname(`node --print "require.resolve('@sandrox/trasivo/package.json')"`.strip), 'ios/trasivo_pods')
use_trasivo!
```

For Expo, add `@sandrox/trasivo` to the `plugins` array. Its optional `photoUsageDescription` sets the host's iOS add-only Photos usage text; `legacyAndroidMediaPermission: true` declares write permission only through Android API 28. The plugin adds the source pod declarations during prebuild. It does not configure cleartext transport, background modes, entitlements or signing. Supply privacy wording suitable for the host and request permission in response to a user action.

The adapter currently links all three native modules. Disabling presentation avoids creating the overlay and panel; it does not remove their code from the binary. Native-only consumers can continue to select core, storage and UI independently.

## Task ownership

Import the singleton from an application service. Screen unmounting removes only that screen's observer. HTTP work, retry callbacks and native presentation belong to the RN runtime, not to a React component. Do not retain a screen in a request-provider closure.

```ts
import { trasivo } from '@sandrox/trasivo';

const stop = trasivo.subscribe(tasks => renderResourceCards(tasks));
await trasivo.refresh(); // also surfaces a missing native installation

if (await trasivo.requestMediaPermission()) {
  await trasivo.download({
    title: 'Photo',
    prepare: async ({ signal }) => ({
      url: await obtainFreshDownloadURL(signal),
      destination: {
        kind: 'media', media: 'image', filename: 'photo.jpg', mimeType: 'image/jpeg',
      },
    }),
  });
}

// On screen unmount:
stop();
```

`subscribe` immediately returns the cached immutable snapshot and then receives native changes. `refresh` obtains current native state; monotonically increasing revisions prevent a late query from overwriting newer events. `retry`, `cancel` and `remove` return whether the native center accepted the action. Render actions from `canRetry`, `canCancel` and `isActive`; finalization cannot be canceled. Removing a record does not delete its saved result.

`clearHistory` refuses while any task is active. Before an account switch, stop accepting new work, cancel cancellable tasks, wait for finalization, then clear history and release account services. No account identity or credential store exists inside Trasivo.

RN reload/runtime invalidation cancels cancellable work, closes presentation, and fails callbacks still waiting for JavaScript. A destination already being committed may finish. JavaScript callbacks cannot survive a runtime restart; Fast Refresh/full reload is not task recovery. There is no durable history, pause, resumable upload/download or background execution guarantee.

## Requests and response validation

`prepare` runs on every attempt, including retries initiated from the native panel. Refresh signed URLs and credentials there. It receives the stable task ID, the new attempt ID and an abort signal. Native completion ignores replies from expired attempts. Host callbacks have a 30-second deadline; timeout becomes `host_timeout`. A provider failure becomes `request_failed`; a validator failure becomes `response_rejected`. Callback exceptions are not copied into native errors.

Downloads accept fresh HTTP(S) GET requests. Destinations are either a new app-owned `file://` URI whose parent already exists, or an image/video media-library item. Existing files are never overwritten. Media filenames and MIME types must match the actual resource. The host handles any later document export separately.

Uploads accept POST, PUT or PATCH and a readable app-owned `file://` URI. Keep the source available and unchanged through all retries. A document provider's URI should be copied into host-owned storage before enqueueing. `body.multipart` encodes a single file and optional string fields as `multipart/form-data`; omitting it sends the raw file. Media bytes do not pass through JavaScript. iOS multipart encoding uses a temporary file retained through network completion.

```ts
await trasivo.upload({
  title: 'Attachment',
  prepare: async ({ signal }) => ({
    url: await obtainUploadURL(signal),
    headers: { Authorization: await obtainAuthorization(signal) },
    body: {
      uri: ownedFileURI, mimeType: 'application/octet-stream',
      multipart: { fieldName: 'file', filename: 'attachment.bin' },
    },
  }),
  validate: response => {
    const body = JSON.parse(response.body);
    if (body.success !== true || typeof body.id !== 'string') throw new Error('Rejected');
    return { remoteId: body.id };
  },
  onRemoved: () => releaseOwnedUploadCopy(),
});
```

HTTP transport rejects non-successful upload status codes and responses larger than 1 MiB. The UTF-8 response and headers are delivered transiently to `validate`; success is withheld until it returns safe metadata. That metadata enters task history: return only necessary non-secret identifiers, never response bodies, signed URLs or authorization values. Metadata, request headers and form fields are string dictionaries bounded to 64 entries, 200 characters per key, 4096 per value, and 16 KiB serialized. Native checks may measure UTF-8 bytes more strictly. `Content-Type` comes from the body description; `Range`, `Content-Length`, `Host` and `Transfer-Encoding` are transport-owned.

`onRemoved` runs when history is removed or evicted by the native history bound. It is not a process-termination notification. Hosts must manage their own cache lifecycle and must never delete borrowed provider files or successful download results through this callback.

## Optional presentation

```ts
await trasivo.setPresentation(true, {
  language: 'zh-Hant',
  theme: { primary: '#3D63E8' },
});
await trasivo.showPanel();
await trasivo.setPresentation(false);
```

Presentation defaults to off. Four explicit languages are supported: `zh-Hans`, `zh-Hant`, `en`, `ja`; the default is Simplified Chinese. Missing theme colors use the native teal palette. Colors are six-digit `#RRGGBB`. Pass host semantic colors again when the host appearance changes. Configuration is replaced on each call, so omitted fields return to defaults.

Cards, the floating indicator and the panel observe the same IDs and attempts. Presentation calls require a foreground host window/Activity. Android reattaches visible presentation after Activity recreation. No system overlay permission or dedicated navigation entry is needed.
