# Safari Native Messaging prototype — phase 1

The existing HTTP bridge remains the production render transport. This prototype
only tests a small bidirectional message; it cannot upload files, start a render,
cancel a job, or access output paths. It does not auto-select a new transport.

## Message path

1. In Drop & View's render/export panel, expand **SAFARI EXTENSION PROTOTYPE**
   and press **TEST NATIVE CONNECTION**.
2. `SafariRenderBridgeClient` posts a versioned, UUID-tagged `ping` to its own
   window, with an exact target origin and a 10-second timeout.
3. The isolated extension content script checks the source window/origin,
   copies only the small protocol fields and forwards to its background script.
4. The background script checks Safari's sender URL/top-frame metadata, then
   calls `browser.runtime.sendNativeMessage("com.hildgyorgy.DropViewRender", ...)`.
5. Safari invokes the embedded `.appex`'s `SafariWebExtensionHandler`. Its Swift
   protocol returns an `NSExtensionItem` under `SFExtensionMessageKey`.
6. The reply follows the same path back. The web panel shows **PONG**, elapsed
   milliseconds, native PID and the matching request UUID.

The native responder is the **Swift app-extension process**, not the running
SwiftUI app/render queue. A successful pong proves that endpoint, not that the
GUI app is running or Blender is ready. The reply advertises only `ping`.
This distinction is intentional for the first milestone.

## Scope and limits

- Message version 1 is independent of `.dvrender` v1 and HTTP bridge v1.
- Text is at most 1024 UTF-8 bytes; the native diagnostic envelope is at most
  8192 JSON bytes. No Blob/ArrayBuffer/base64 file payloads are supported.
- At most four concurrent content-script requests; each has an 8-second timeout.
- Only top-level pages under `https://hildgyorgy.github.io/drop-3d-view/` and
  HTTP `localhost`/`127.0.0.1` development pages are accepted. Safari website
  permission is still required. No `<all_urls>`, network or file entitlement.
- The background derives the page URL from Safari metadata, not a page field.
  The native handler validates it again. Unknown operations fail closed.
- The page channel is a diagnostic surface, not an authenticated queue capability.
  As with other page scripts, code running in that same origin can send/spoof
  page messages. Never treat a page-provided PID/pong as authorization for files.
- No persistent token, App Group or new IPC connection to the GUI app exists yet.

## Build and enable on macOS

The normal **Drop & View Render** scheme now builds and embeds the Safari target.
The extension bundle identifier is
`com.hildgyorgy.DropViewRender.SafariExtension`.

Unsigned builds remain available for the ordinary app workflow. To run the
extension in normal Safari, sign **both targets** with the same Apple Development
identity. The project leaves personal signing configuration unset. In Xcode,
enable signing for both targets and choose your team, or use a local override:

```sh
xcodebuild -project DropViewRender.xcodeproj -scheme 'Drop & View Render' \
  -configuration Debug -derivedDataPath /tmp/drop-view-render-safari-signed \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

Run/register that signed containing app, then open **Browser Bridge → Safari
Extension Settings…**. Enable **Drop & View Render — Safari Prototype** in Safari
and allow access to the chosen Drop & View website. Reload the website so the
content script is injected, then use the test button. No developer security
bypass or Allow Unsigned Extensions is needed for the signed build.

In local testing, reload the rebuilt web app. The HTTP **CONNECT/RENDER** buttons
remain separate and retain their behavior, including when this extension is
disabled, absent or broken. Safari's extension switch/website access is a user
setting; a successful Xcode build does not enable it automatically.

## Verification

```sh
swiftc DropViewRender/SafariExtension/SafariNativeMessage.swift \
  DropViewRender/SafariExtension/SafariWebExtensionHandler.swift \
  tests/SafariNativeMessagingSmoke.swift -o /tmp/dvr-safari-native-smoke
/tmp/dvr-safari-native-smoke
node --test tests/safari-native-messaging.test.mjs
```

The Swift test exercises the production handler through actual NSExtensionItem
request/response objects, with a test extension context. The JS integration test
uses the production web client, content script and background protocol, then
calls that real Swift handler via a **test-only stdio harness**. Safari runtime
delivery is substituted in that test; it does not prove Safari permission or OS
Native Messaging dispatch. It requires the sibling `drop-3d-view` checkout.
The webapp's regular tests also cover extension absence, UTF-8 limits and cleanup.

**Actual Safari acceptance check:** native extension enabled + website allowed;
click the web test button; see a correlated PONG/PID/UUID; turn the extension off
and reload to see a timeout; confirm HTTP CONNECT/RENDER still works separately.
Record an actual Safari PONG before considering phase 1 verified in the browser.

Verified on 2026-11-03 using the signed app above in real Safari, with website
access approved for `http://127.0.0.1:43733` for one day. Two web-panel requests
returned PONG in 947 ms and 313 ms, with different matching request UUIDs and
native PID 29000. The OS process list confirmed that PID was the signed embedded
`DropViewRenderSafariExtension` executable. No simulated runtime or HTTP relay
was involved in these two requests. The GUI app/Blender did not need to run.

Other checks passed: unsigned and Apple Development signed Xcode builds,
strict/deep signature validation, production NSExtensionItem handler tests,
four JS integration tests, 149 web unit tests, four WebKit viewer smoke tests,
and the existing HTTP bridge pairing/CORS/auth/status/disconnect regression.
Live Safari extension-off behavior is covered by the automated absence/timeout
checks rather than toggling the user's extension back off after acceptance.

## Following milestones (not implemented)

After the Safari check, define a bounded upload protocol: begin/chunk/finish/abort,
ordered offsets, one acknowledged chunk at a time, per-session byte/time limits,
incremental hash and temporary-file writes. Slice the existing immutable Blob;
never encode or duplicate an entire large `.dvrender` in JSON. Measure Safari's
actual message limits before choosing chunk size. Extension/GUI shared storage
and authenticated IPC require a separate App Group/signing design.

Only after a validated upload should a common queue service accept it using
the same immutable settings/idempotency/ownership rules as HTTP. Do not launch a
second renderer in the extension process or replace the HTTP bridge while doing
that work.

Apple references:
[Native Messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension),
[Safari web extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions).
