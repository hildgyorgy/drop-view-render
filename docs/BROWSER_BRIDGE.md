# Browser bridge v1

The native app owns an HTTP/1.1 listener at `127.0.0.1:43127` for its lifetime.
It never binds to the LAN; port conflicts are visible in the Browser Bridge
menu. There is no separate daemon or browser extension. This protocol is
versioned independently of the unchanged `.dvrender` v1 package.

## User workflow

1. Run the rebuilt Drop & View Render app and choose Blender if necessary.
2. In the updated web app choose FILE → EXPORT → CONNECT. Grant browser
   local/loopback access if requested, then Allow in the native approval sheet.
3. Compose a scene, set IMAGE / SAMPLES as usual, turn SECTION off, then RENDER.
4. The shared SAVE PACKAGE exporter captures the current materialized GLB,
   view, HDRI, render targets and thumbnail. Upload happens locally, without a
   download or developer-operated server.
5. After the native app accepts the job, the browser displays sample progress,
   elapsed time and the finished output name. CANCEL targets this job only.
6. SHOW IN FOLDER activates Finder in the foreground and reveals the completed image. Output defaults to
   `~/Downloads/Drop & View Render/<model>-cycles.png`; collisions use the next
   free `-001`, `-002`, … filename. Old images are preserved.

Web submissions use Recommended quality: source dimensions, sample maximum and
bounce limits, adaptive sampling at 0.03 and OIDN denoise. No global/native job
preferences are changed. The native app serializes browser submissions: compose another camera while a
render runs and press RENDER again to queue a new immutable snapshot. It starts
after the current render/previous browser submissions finish, without starting
unrelated local jobs. An explicitly started native batch finishes before pending
browser jobs. The web job selector keeps earlier submissions available for
progress, cancellation and output reveal. All accepted jobs also appear natively.
A queued browser job retains its accepted quality settings. Web CANCEL removes
a waiting job or interrupts the selected active job and then continues the
remaining browser queue. The native toolbar Cancel pauses automatic continuation;
a new explicit submission or native Render resumes processing. SAVE PACKAGE remains available.

Disconnecting/reloading the browser does not cancel an accepted render. A lost
submission response keeps the same immutable Blob and request UUID for RETRY
SEND, so retrying cannot duplicate a render. Retry resends that saved scene,
not later viewer edits. Once acceptance is confirmed, another RENDER captures a
new scene and ID. Browser state is not persisted across tab reloads. Existing
jobs can still be inspected in the native app.

## Trust and authentication

All requests require an exact `Origin`. Allowed origins are
`https://hildgyorgy.github.io` and HTTP `localhost` / `127.0.0.1` origins for local
development. Native approval covers the whole origin, not a URL path: GitHub
Pages projects on the same hostname share an origin. CORS does not replace auth.
Tokens bind to that origin and stay in native/browser-tab memory only, never
URLs, logs, cookies or localStorage. Native approval explicitly describes scene
upload, rendering, cancellation and output reveal. Each job is accessible only
to authenticated sessions from its submitting origin.

App quit and Browser Bridge → Disconnect Browsers revoke sessions. Per-tab
DISCONNECT revokes that token. A restarted/revoked session returns 401 and needs
new approval. This boundary does not defend against malicious native processes
running as the same local user.

## API

- `POST /v1/pair`: native approval; returns `{ protocolVersion: 1, token }` after
  Allow. Deny is 403; concurrent/rate-limited approval attempts are 429.
- `DELETE /v1/pair`: authenticated session revocation.
- `GET /v1/status`: authenticated; `app`, `appVersion`, `protocolVersion: 1`,
  `capabilities: ["status", "jobs", "cancel", "reveal"]`, `blenderAvailable`,
  `rendering`. Older status-only clients remain compatible.
- `POST /v1/jobs`: authenticated, fixed `Content-Length`,
  `Content-Type: application/octet-stream`; body is the original `.dvrender`
  Blob. Required `Idempotency-Key` is a UUID and `X-DVR-Settings` is JSON
  `{"version":1,"profile":"recommended"}`. Unknown settings are rejected;
  custom overrides are not supported in this version. This small separate
  envelope avoids multipart buffering and does not change the scene format.
  Returns **202 `{id}` only after complete upload, package validation and native
  job creation/queueing**. A render can subsequently fail; 202 is not completion.
- `GET /v1/jobs/{id}`: `id`, `state` (`queued`, `rendering`, `finished`,
  `cancelled`, `failed`), optional sample `progress` (0–1), `elapsed` seconds,
  `outputName`, optional `queuePosition` (1-based among waiting browser jobs), optional error and actual per-run settings. No raw logs or
  arbitrary filesystem endpoints. Removed jobs return 410; unknown/other-origin
  IDs return 404. Progress is sampling progress, not a total-time estimate.
- `POST /v1/jobs/{id}/cancel`: targets that active or waiting job; repeated terminal
  cancellation is harmless. Cancellation uses the existing native escalation.
- `POST /v1/jobs/{id}/reveal`: native Finder action only for a finished owned job.
- `OPTIONS`: exact-origin CORS, only Authorization, Content-Type,
  Idempotency-Key and X-DVR-Settings headers. Actual operations require auth.

## Upload storage and limits

One upload at a time, max 2 GiB/package and the unchanged manifest/resource
validation rules; 16 KiB headers, 1 KiB control bodies, 16 concurrent connections.
Control/approval connections have a 120-second deadline, uploads 600 seconds.
No chunked bodies, pipelining, remote Host, redirects, executable payloads or
browser-supplied file/output paths. Inputs are streamed in at most 64 KiB chunks
to a private randomly named temporary directory (0700; files 0600); the full
package is never accumulated in server RAM. Package SHA-256 is computed while
writing. Interrupted/rejected uploads are removed. Auth is checked before
writing and again at completion. Same origin/key/digest returns the original
job ID; same key with different bytes returns 409 without another render.

Accepted packages stay available for native rerender until normal app quit,
then input storage is removed after Blender stops; completed Downloads images
remain. Crashes can leave OS temporary files; there is no persistent native job
history or automatic crash recovery. Per app session, accepted inputs are capped
at 8 GiB and 64 jobs; rejected uploads consume neither quota. Existing IDs can
still be retried at these limits. No image, Blender binary or Python runtime is
bundled by this feature.

## Validation and browser limits

Native connection smoke (macOS; port 43127 must be free):

```sh
swiftc -parse-as-library DropViewRender/BrowserBridge.swift DropViewRender/DVRenderManifest.swift tests/BrowserBridgeSmoke.swift -o /tmp/bridge-smoke
/tmp/bridge-smoke
```

`tests/BrowserRenderSmoke.swift`, compiled with the model/bridge sources in a
temporary `.app` containing the existing adapter resources, takes a real package
and makes an explicit 64×64 / 2-sample fixture. It verifies a real Cycles render,
status, duplicate replay, conflicting replay, indexed rerender, cancellation,
old-image preservation serial browser queueing, immutable accepted settings and isolation from an unrelated queued native job.

2026-11-02 checks: native build and HTTP smoke, real render smoke, 146 web unit
tests, 3 existing WebKit viewer smoke tests and both public renderer builds.
An Edge test using the real viewer/exporter and native HTTP bridge completed
RENDER → FINISHED and a second RENDER → CANCELLED without page errors. Approval
was injected in automated render tests; the previous production-app UI check
verified the real native Allow sheet, Blender status and shutdown.

The earlier Edge HTTPS-origin CORS probe passed with loopback permission granted.
Automated WebKit blocked that HTTPS → HTTP loopback request as mixed content;
Safari is not declared supported. User confirmed connection READY on 2026-11-02.
A real published-site/browser render test remains necessary. Local HTTP-only
success is insufficient to prove HTTPS compatibility. The client requests
`targetAddressSpace: "loopback"` only after an explicit CONNECT click; failures
retain SAVE PACKAGE. See the official
[Chrome Local Network Access guide](https://developer.chrome.com/docs/modern-web-guidance/guides/security/local-network-access).

No commit, push or publication happens automatically. Windows tray/GPU discovery,
custom web quality overrides, output download and persistent job history remain
separate future work.

Follow-up checks (2026-11-02): real Cycles tests passed for serial submissions,
queued and active cancellation, frozen accepted quality, and unrelated-job
isolation. Edge viewer test submitted a second camera while the first rendered;
both finished and either output was selectable. Native build, 146 unit tests and
3 WebKit smoke tests passed. Finder uses explicit workspace activation; the
manual foreground check was interrupted by UI automation timeouts and needs
user verification.
