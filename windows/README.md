# Drop & View Render for Windows (prototype)

A Windows 11 x64 per-user tray application with no main window. The browser is
the scene/queue UI. It uses the same Chrome/Edge extension, `.dvrender` v1 package
and production Blender adapter as macOS. Safari is not included.

## User workflow

1. Install stable Blender **5.3.0** (or a later 5.3 maintenance release).
   Blender 5.2.3 LTS remains supported as a compatibility fallback.
   Blender is external; this package does not vendor Blender or a Python runtime.
2. Install the per-user Drop & View Render package and launch it from Start.
   Its icon appears beside the clock, sometimes inside Windows' overflow area.
3. Install/enable the companion Chrome/Edge extension. Until store publication,
   use Developer mode → Load unpacked and choose the installed `ChromiumExtension`
   folder (a Start-menu shortcut opens it). Reload the Drop & View page.
4. In the webapp: i → RENDER WITH BLENDER → EXPORT → CONNECT. Approve the native
   dialog for that website; RENDER submits the current immutable scene.
5. The page shows queue/status/progress, CANCEL and SHOW IN FOLDER. New camera
   snapshots can be sent while earlier jobs render serially. Outputs default to
   the Windows Downloads known folder / Drop & View Render, with numbered names.

Tray menu: readiness/progress, open webapp/output folder, choose output folder,
choose Blender, open diagnostics, cancel renders, disconnect browsers, optional start at sign-in,
and Quit. Startup at sign-in is off by default. Closing the browser does not stop
accepted renders. Quitting the tray app cancels jobs and removes its session
inputs; a Windows Job Object also terminates owned Blender children if the tray
process crashes. Original packages and finished images are never deleted.
A connection approval expires at app exit or Disconnect Browsers.

Blender is detected under Program Files / Blender Foundation / Blender 5.3*
first, with Blender 5.2* as a fallback, ordered by numeric version. The executable
is verified via `--version`; a selected custom path is persisted and keeps priority. No beta
Blender or administrator privileges are required. Run the tray app as the normal
logged-in user, not elevated. GPU AUTO tries NVIDIA OptiX, CUDA, AMD HIP, Intel
oneAPI, then explicitly reports CPU fallback. Resolution, sample cap and bounce
counts are preserved. Recommended uses adaptive threshold 0.03 and OIDN.
Actual Windows vendor GPU/driver compatibility requires testing on Windows.
Open diagnostics reveals per-job Blender logs under LocalAppData / DropViewRender /
Logs, including device selection and errors. At most 32 logs are retained, each
limited to one million characters; diagnostic write failures do not stop rendering.

## Architecture

- `Core`: bounded framed JSON, v1 package validator, per-session authorization,
  streaming upload staging/SHA-256/replay/dedup, serial queue and subprocess runner.
- `NativeHost`: Chrome/Edge Native Messaging stdio executable. Validates the
  exact caller extension ID derived from the shared public manifest key before
  forwarding requests through a per-user/per-logon-session named pipe.
- `Tray`: WinForms ApplicationContext + NotifyIcon, native approval, settings,
  Blender discovery, known Downloads folder, optional HKCU startup and kill-on-close
  Job Object ownership. No Windows Service, public HTTP listener or Safari code.
- `Tests`: dependency-free console checks; they also run on macOS for the shared
  core and can launch the actual bundled Blender adapter for a small smoke render.

Pipe servers use `PipeOptions.CurrentUserOnly`; at most four clients each receive
frames capped at 100,000 bytes before allocation. The Chrome/Edge port persists
for chunk streams. The native helper can start the tray app using a breakaway
process so browser shutdown cannot own/kill the render queue. If OS policy denies
breakaway, launch the tray app manually and reconnect. Do not fall back to a
browser-owned render process.

Only the Drop & View GitHub Pages project and HTTP localhost/127.0.0.1 development
pages are allowed. Background sender metadata provides the page URL. Native
pairing binds random 72-character credentials to the origin; tokens remain in
memory and are not written to settings, outputs or logs. Same-user native malware
is outside this boundary, as on macOS.

Upload chunks are at most 64 KiB, one acknowledged slice at a time, with SHA-256,
ordered offsets and byte-checked prefix replay. Up to four incomplete uploads,
4 GiB reserved active bytes, 8 GiB accepted session input, 128 upload records/jobs,
and 16 paired sessions are allowed. Idle incomplete inputs expire after 15 minutes
when the next upload begins. No whole-package JSON/base64 allocation occurs.
Finish validates the v1 manifest/resource lengths, GLB header, HDRI limits and a
streamed full digest before queueing. Same origin/key/digest returns one job;
changed bytes conflict. Accepted inputs remain for the app session; normal quit
removes them and the next start cleans abandoned session caches.

Every job freezes its package targets/output path. A successful nonempty staged
image is moved without replacement to its final path; failure/cancellation deletes
staging. Other existing output images are preserved even if a filename race occurs.
Only owned, finished job IDs can reveal an output. No browser-supplied file paths
or arbitrary commands are supported. Settings/output changes affect future jobs.

## Build and tests

Requires the **.NET 10 SDK** for development only. End-user bundles are self-contained.
From the repository root:

```sh
dotnet build windows/Tray/DropViewRender.Tray.csproj
dotnet build windows/NativeHost/DropViewRender.NativeHost.csproj
dotnet run --project windows/Tests/DropViewRender.Tests.csproj
# Optional actual Cycles smoke, explicit 64×48 / 1-sample test fixture only:
dotnet run --project windows/Tests/DropViewRender.Tests.csproj -- \
  path/to/scene.dvrender path/to/blender path/to/DropViewRender/Resources/render_glb.py
```

The projects can cross-build on macOS (`EnableWindowsTargeting`); the tray GUI
cannot run on macOS. A compile/core test is not proof of Windows UI, native host
registration, Chromium process lifetime behavior or GPU drivers.

On Windows with PowerShell 7:

```powershell
./windows/publish.ps1
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" windows/installer/DropViewRender.iss
```

`windows/artifacts/win-x64` contains the portable self-contained app plus helper,
shared adapter/HDRI and complete shared extension. ZIP and Inno Setup per-user
installer are under `windows/artifacts`. The installer registers the exact
Native Messaging host under HKCU for Chrome and Edge and adds Start shortcuts;
startup remains opt-in. Quit the tray app before installing/updating/uninstalling.
The installer does not install Blender or silently enable a browser extension.
The portable ZIP requires host registration via the script below.

The GitHub Actions **Windows tray app** workflow runs core/named-pipe tests,
actual Windows Job Object lifetime and published-host stdio/pipe checks, then
publishes the bundle, compiles the installer and uploads ZIP/Setup artifacts.
It does not publish a release or embed certificates. It only runs remotely after
these changes are committed/pushed or dispatched on a branch containing it.
Installer code signing/store publishing remain release work; these are unsigned
prototype builds. No successful remote CI or Windows UI/GPU run is claimed yet.

## Portable registration

After extracting the ZIP to a stable folder, run `Register-Browsers.ps1` from that
folder in PowerShell as the normal user. It creates `native-host.json` and the
user-level Chrome/Edge NativeMessagingHosts registry entries for this helper.
Repeat after moving the folder. The bundled extension ID is derived during
packaging; store publication must preserve it or update registration and caller
validation together. Disable/remove the extension in the browser normally.

References:
[.NET support](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core),
[CurrentUserOnly pipes](https://learn.microsoft.com/dotnet/api/system.io.pipes.pipeoptions),
[Cycles GPU devices](https://developer.blender.org/docs/features/cycles/devices/).
