# Chrome / Edge extension prototype (macOS)

The app bundles one shared Manifest V3 Chromium extension and a compiled Swift
native messaging host. Chrome and Edge use the same extension source. This is a
macOS prototype, not the future Windows app or a store-published extension.

## Install for local testing

1. Build/run the Drop & View Render scheme. It embeds the helper under
   `Contents/MacOS/DropViewRenderNativeHost` and the complete unpacked extension
   under `Contents/Resources/ChromiumExtension`. No extra Python/runtime is used.
2. Keep the app in a stable location. Use **Browser Bridge → Set Up Chrome /
   Edge… → Register and Show Extension**. This registers the helper for the
   current macOS user, only for installed browsers, then reveals the extension.
3. In `edge://extensions` or `chrome://extensions`, enable Developer mode and
   **Load unpacked**, choosing the revealed folder. Enable website access for
   the Drop & View site / local development site, and reload that page.
4. In i → RENDER WITH BLENDER → EXPORT, press CONNECT. It discovers the installed extension, then requests native pairing.
   RENDER uses the same immutable snapshot and native queue as Safari/HTTP.
5. Missing extensions produce install/enable/reload guidance, with SAVE PACKAGE
   available. There is no transport selector or direct browser HTTP fallback.

Host registrations are named `com.hildgyorgy.dropviewrender.json` under:

- `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
- `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/`

They contain the absolute bundled helper path, type stdio, and one exact allowed
extension origin. Repeat setup after moving the app. Removing this registration
file disconnects that browser from the helper; disabling/removing the extension
uses the browser's normal extension controls. Do not remove other hosts.

The manifest's public key pins the unpacked ID to
`jfbkhccnkpadgimkmcnppodfoccadelm` across paths and both browsers. It is public
identity material, not a private key/credential. Future store publishing must
preserve this identity or explicitly update both helper caller validation and
installed host allowed_origins; do not use wildcard origins. App notarization,
Chrome Web Store/Edge Add-ons publishing and a release installer are still needed
for a normal end-user distribution without Developer mode.

## Architecture and limits

The web client sends the same protocol-v1 bounded window messages as Safari.
The isolated content script checks window/origin; the shared background protocol
checks the actual top-level tab sender URL and copies only allowed fields. Only
Drop & View's GitHub Pages project and HTTP localhost/127.0.0.1 are allowed.

`discover` is answered in the background, without launching a native process,
pairing or claiming Blender readiness. Queue operations use a persistent
`chrome.runtime.connectNative` port to the registered lowercase host name.
The helper checks its Chromium caller origin against the ID derived from the
bundled extension key before reading requests. Each frame is four little-endian
length bytes followed by UTF-8 JSON; the Mac target is little-endian. It rejects
zero/oversized (>100,000 bytes), malformed or truncated frames before dispatch.
No stdout logging is allowed: stdout contains framed protocol responses only.
A fixed generic stderr diagnostic excludes payloads, credentials and paths.

The helper reuses the production Swift router and staging store. At most 64 KiB
raw data is sent per acknowledged chunk, with per-chunk SHA-256, ordered offsets,
verified replay, ownership, quotas and commit leases. See
[shared transfer rules](SAFARI_NATIVE_MESSAGING.md). The persistent background port
has at most four pending RPCs and releases each payload on response/timeout.

On finish the native helper streams the staged file to the existing
`127.0.0.1:43127` HTTP service using native URLSession. Safari/Chromium pages never
fetch localhost in extension mode. The GUI app must be running. Existing native
approval, origin-bound memory-only tokens, package validation, full-digest
idempotency, immutable Recommended settings, queue/status/cancel/reveal and
numbered output filenames are reused. No second renderer or queue is introduced.

## Build / verification

The normal Xcode scheme builds the helper target and copies/signs it into the
app. Signed Safari testing still needs the same Apple Development identity for
all targets. No personal signing configuration is committed.

```sh
xcodebuild -project DropViewRender.xcodeproj -scheme 'Drop & View Render' \
  -configuration Debug -derivedDataPath /tmp/dvr-chromium CODE_SIGNING_ALLOWED=NO build
node --test tests/chromium-native-messaging.test.mjs
```

The test defaults to the app in that build directory; set `DVR_CHROMIUM_APP` for
another build. It exercises real helper framing, partial reads, multiple messages,
caller denial, size/truncation/JSON rejection and the actual production
content/background code with a substituted browser runtime. It does not alone
prove browser installation, permissions or OS dispatch.

`SafariTransferSmoke.swift` also accepts a helper executable as its second
argument (after the fixture). With the production model/HTTP sources and
`BrowserExtensionIdentity.swift`, it tests framed helper → authenticated native
HTTP → actual Cycles queue, PNG, chunk/finish/full retry dedup and status.
Only its fixture uses explicitly tiny test settings. Port 43127 must be free.

Actual Edge acceptance on 2026-11-04, user-approved local site 127.0.0.1:43733:

- app setup registered the helper and Load unpacked loaded version 0.2.0;
- AUTOMATIC detected CHROME / EDGE EXTENSION, with native pairing approval;
- 1512×1774 / explicitly selected four-sample render finished in 6 seconds;
- after restoring the field to 500, rerenders finished in 10 seconds each, using
  `-002` and `-003` names rather than overwriting the first render;
- a subsequent render was explicitly cancelled and the page showed CANCELLED;
- selecting the earlier finished job and SHOW IN FOLDER selected its PNG in Finder.

Validation also passed: 156 web unit tests, four WebKit viewer smoke tests,
seven Safari/Chromium JS/native integration tests, native NSExtensionItem smoke,
real framed helper/Cycles queue smoke, signed/unsigned Xcode builds and strict
app/helper signature checks. The Safari GUI recheck timed out at computer-use
app access; its new discovery is covered by automated tests, not a new live claim.

Chrome is not installed on this Mac: its actual browser check remains. Public
HTTPS deployment and store installation have not been acceptance-tested. The
shared `.dvrender` v1 adapter/material/camera/quality policies are unchanged.

References: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging),
[Edge Native Messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging).
