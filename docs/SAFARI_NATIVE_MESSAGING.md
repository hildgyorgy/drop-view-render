<!-- Current common Chromium setup: see CHROMIUM_NATIVE_MESSAGING.md. -->
# Safari Native Messaging prototype — chunked transfer and queue

CONNECT automatically detects Safari or Chrome/Edge and uses its extension.
There is no transport selector, direct browser HTTP client or HTTP fallback.
The diagnostic TEST NATIVE CONNECTION ping remains separate and does not prove
that the GUI app or Blender is running. The user confirmed the Safari extension
connection works on 2026-11-04.

## Message path and use

1. Run the signed Drop & View Render app and enable its Safari extension for
   the chosen website. Reload the updated webapp.
2. Open i → RENDER WITH BLENDER → EXPORT, CONNECT,
   and approve pairing in the native app. Then press RENDER.
3. The web client slices the immutable `.dvrender` Blob into 64 KiB chunks.
   Content script → background → Safari Native Messaging delivers each chunk
   to `SafariWebExtensionHandler`, waiting for an acknowledgement before sending
   the next. No browser localhost fetch is used on this path.
4. The Swift extension stages chunks on disk. On finish, native URLSession
   streams that file to the existing loopback HTTP queue service at
   `http://127.0.0.1:43127/v1/jobs`, with the original submission UUID.
5. The existing validator, ownership checks, recommended settings and serial
   RenderQueueModel browser queue handle the accepted job. Status, CANCEL and
   SHOW IN FOLDER use the same Native Messaging/native HTTP relay.

This prototype deliberately reuses the native HTTP service; it is not an App
Group/XPC implementation. The containing app and its listener must be running.
The native HTTP relay remains internal; the direct browser HTTP transport is retired.

## Protocol, memory and retry rules

- Message protocol v1 is independent of `.dvrender` v1 and HTTP bridge v1.
- Operations: ping, pair, status, disconnect, job, cancel, reveal, uploadBegin,
  uploadChunk, uploadFinish and uploadAbort. Requests carry a correlated UUID.
- A chunk is at most 65,536 raw bytes / 87,384 base64 characters, with SHA-256
  and an ordered byte offset. Native envelopes are capped at 100,000 JSON bytes;
  diagnostic ping envelopes remain capped at 8,192 bytes.
- Neither the browser client nor native staging reads/encodes the entire package
  into a message. Native final submission uses URLSession upload from a file
  with explicit Content-Length.
- Repeated chunks are acknowledged only when their bytes match the stored
  prefix. Reopening an incomplete submission starts at zero and verifies that
  prefix. Changed bytes or offsets fail closed.
- The browser retains the same immutable Blob and submission UUID after an
  ambiguous send failure. RETRY SEND can safely replay it; the existing HTTP
  service validates the full package digest and prevents duplicate queue jobs.
  Repeated finish on an accepted upload returns its recorded job UUID.
- STOP SENDING aborts an uncommitted upload. Once validation/submission starts,
  wait for acknowledgement, then use the ordinary queue CANCEL action.
- Staging permits files from 24 bytes to 2 GiB, at most four active uploads,
  4 GiB reserved bytes and 128 records. Idle incomplete uploads expire after
  15 minutes; accepted receipts after 24 hours, swept at the next begin.
- A process-shared file lock protects metadata/payload updates. Commit leases
  last 600 seconds. Private staging uses directory mode 0700 and file mode 0600;
  accepted staged payloads are deleted. The GUI retains its own accepted input
  for its existing queue/rerender lifecycle.

## Authorization

Only top-level `https://hildgyorgy.github.io/drop-3d-view/` pages and HTTP
localhost/127.0.0.1 development pages are accepted, with Safari website permission.
The background derives the URL from Safari sender metadata; Swift validates it
again. Bounded, operation-specific fields are copied, not arbitrary page objects.
Pairing uses the existing native approval and origin-bound memory-only token.
Staging ownership hashes the origin/token combination. A pong is diagnostic,
not authorization to submit a job.

The extension has outbound network-client entitlement for its fixed native
loopback relay. It refuses redirects, disables cookies/proxies and never accepts
an arbitrary destination URL. No App Group, new public listener, bundled Python
or Blender is introduced.

## Build and enable

The normal Drop & View Render scheme embeds
`com.hildgyorgy.DropViewRender.SafariExtension`. Sign both targets with the same
Apple Development identity; personal signing configuration remains unset:

```sh
xcodebuild -project DropViewRender.xcodeproj -scheme 'Drop & View Render' \
  -configuration Debug -derivedDataPath /tmp/drop-view-render-safari-signed \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

Run/register that app, then use Browser Bridge → Safari Extension Settings…
to enable **Drop & View Render — Safari Prototype** and website access. Reload
the website. No Allow Unsigned Extensions/security bypass is needed. Unsigned
builds remain available for the ordinary app workflow.

## Verification

```sh
swiftc DropViewRender/SafariExtension/*.swift \
  tests/SafariNativeMessagingSmoke.swift -o /tmp/dvr-safari-native-smoke
/tmp/dvr-safari-native-smoke
node --test tests/safari-native-messaging.test.mjs
swiftc DropViewRender/SafariExtension/SafariNativeMessage.swift \
  DropViewRender/SafariExtension/SafariUploadStore.swift \
  tests/SafariUploadStoreSmoke.swift -o /tmp/dvr-safari-upload-smoke
/tmp/dvr-safari-upload-smoke
/usr/bin/time -l /tmp/dvr-safari-upload-smoke --stress
```

`SafariTransferSmoke.swift` combines the production router/store, HTTP service
and RenderQueueModel, with explicit small test resolution/sample settings. It
renders a real temporary `.dvrender` with Cycles and verifies same-ID chunk,
finish and whole-submission retries produce one job. It requires the app
resources and the local demo package; keep port 43127 free for that harness.

Verified in this milestone: signed/unsigned Xcode builds; signature validation;
native handler/store tests; four JS native messaging integration tests; 153 web
unit tests; four WebKit viewer smoke tests; real queue/Cycles render. The
standalone 256 MiB staging stress test peaked at 8,798,208 bytes (~8.4 MiB) RSS.
That number measures the staging harness, not total Safari or Blender memory.

Real Safari, local 127.0.0.1:43733 with user-approved extension/site access:
ping/pong was verified first (947/313 ms). In the second milestone, selecting
SAFARI EXTENSION, pairing and RENDER transferred the actual demo package through
the extension and produced a native Finished render in 7 seconds at the original
3456×2168 resolution, with an explicitly selected 1-sample test limit. The sample
field was restored to 500. The background Safari panel retained a stale rendering
label; manual/visibility/focus refresh handling was subsequently improved. That
final UI refresh still needs live Safari re-verification. Live queue cancellation
and a public HTTPS deployment have not yet been acceptance-tested. Automated
checks cover abort-before-submit, checksum/offset/owner failures, retry/dedup and
native status roundtrips. Public use needs deployment of the updated web bundles.

Apple references:
[Native Messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension),
[Safari web extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions).
