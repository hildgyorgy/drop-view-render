# macOS Developer ID release

The public artifact targets Apple Silicon / macOS 14+. It contains the SwiftUI
app, one sandboxed Safari web extension, the Chromium native helper, browser JS,
Blender adapter and CC0 environment. Blender/Python are not bundled.

## Prerequisites

- Xcode command-line tools and a valid **Developer ID Application** signing
  identity with its private key in the login Keychain. Apple Development and
  Apple Distribution are not substitutes for GitHub/DMG distribution.
- Apple Developer Program membership. The Account Holder creates the Developer
  ID certificate in Xcode → Settings → Accounts → Manage Certificates.
- A notarytool Keychain profile. Create it interactively in Terminal, keeping
  the app-specific password out of chat, scripts, Git and shell arguments:

  ```sh
  xcrun notarytool store-credentials DropViewRender-notary
  ```

  Follow the secure prompts with the Apple ID, Team ID and app-specific password;
  an App Store Connect API key is another supported notarytool option. Validate
  access with `xcrun notarytool history --keychain-profile DropViewRender-notary`.
- GitHub CLI (`gh auth login`) authorized to push this repository and create
  Releases/upload assets. The connected source-code plugin does not expose
  binary Release asset upload; the release script uses the CLI for this step.

No credentials, .p12 files, provisioning profiles or certificates belong in Git.
The basic Safari sandbox/network-client entitlements need no App Group. All
three executables are explicitly signed inside-out, using one Developer ID team,
secure timestamps and hardened runtime. `--deep` is for verification, not signing.
Default Xcode development builds retain their existing unsigned configuration;
release signing is an explicit step over a Release build, never a bypass.

## Review and validation

Inspect native and sibling webapp Git status first. Commit the reviewed changes;
record the exact public web commit used for acceptance. Build and publish refuse
a dirty native worktree. Keep the app IDs stable so Safari retains its identity.
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` flow to both app and extension.
The JS manifest version is also stamped in the release build before signing.

For a local unsigned Release check (not distributable):

```sh
python3 tools/macos_release.py build --version 0.3.0 --build-number 3 --unsigned-check
```

Use a fresh build number/output directory for the real build. Exact identity
hashes can be obtained with `security find-identity -v -p codesigning`.

```sh
python3 tools/macos_release.py build --version 0.3.0 --build-number 4 \
  --identity 'Developer ID Application: NAME (TEAMID)'
python3 tools/macos_release.py notarize-app \
  '.build/macos-release/0.3.0-4/Drop & View Render.app' --profile DropViewRender-notary
python3 tools/macos_release.py dmg \
  '.build/macos-release/0.3.0-4/Drop & View Render.app' \
  --identity 'Developer ID Application: NAME (TEAMID)' --profile DropViewRender-notary
```

The build stamps matching versions, signs extension → helper → containing app,
checks signatures/team/runtime/timestamp and absence of get-task-allow, then
records source provenance. The app is submitted first and its ticket stapled.
DMG creation copies that stapled app plus an Applications link and installation
notes; the image is signed, separately notarized and stapled. Both app and DMG
must pass stapler/Gatekeeper checks. SHA256SUMS.txt covers the final stapled DMG.
Outputs live under ignored `.build/macos-release`; existing outputs are preserved.

Prepare reviewed release notes in a text file. Publish only after all checks:

```sh
python3 tools/macos_release.py publish \
  .build/macos-release/0.3.0-4/DropViewRender-0.3.0-macOS-arm64.dmg \
  --tag v0.3.0 --notes docs/releases/0.3.0.md
```

The command checks clean source/provenance/tag/checksum/notarization, pushes HEAD
to main (no force), then creates the GitHub tag/Release with DMG and checksums.
It fails if an existing tag/Release conflicts; it never overwrites public assets.
No CI signing secrets are required for this local release flow.

## Download/install acceptance

After publication, download the DMG **through Safari from the GitHub Release**,
not from the local build folder. Check its SHA-256 against the published checksum.
Preserve quarantine; run stapler validate and spctl assessment on the downloaded
image and installed app. Quit the old app gracefully (wait/cancel active jobs),
retain a recoverable copy, install into /Applications and launch that exact copy.
Do not disable Safari extension signing checks or Gatekeeper. Enable extension
and website access if Safari requests it, reload the public HTTPS webapp and pair.

Submit four explicit small test jobs (all four DENOISE/ADAPTIVE combinations).
Check the browser-reported immutable settings, native job snapshot and Blender
output/runtime verification agree; verify successful PNG, dimensions, samples,
bounces, output numbering and completion status. Test another camera while the
first job is running, cancel a queued/active test job and reveal a finished PNG.
Restore the user's quality settings after testing. Tiny resolution/sample targets
are explicit test choices only; never alter production requests silently.

Record versions, native/web commit, release URL, downloaded checksum, installed
path, Gatekeeper/stapling results and each real Safari test outcome. A native
router/Cycles smoke proves the relay/queue, but not Safari OS dispatch, permissions
or a downloaded release installation. Do not label an unsigned/local test as
release acceptance.

References: [Apple Safari distribution](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
