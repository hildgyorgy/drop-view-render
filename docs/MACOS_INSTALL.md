Drop & View Render — macOS installation

Requires an Apple Silicon Mac with macOS 14 or later and an external installation
of Blender 5.2.3 LTS. Blender and Python are not bundled in this download.

1. Download the macOS-arm64 DMG from the official GitHub Release:
   https://github.com/hildgyorgy/drop-view-render/releases
2. Open the DMG and drag Drop & View Render into Applications. Eject the DMG.
3. Launch Drop & View Render from Applications and choose the installed Blender
   if it is not detected. Keep the render app running.
4. In Safari → Settings → Extensions, enable Drop & View Render and allow it on
   https://hildgyorgy.github.io/drop-3d-view/ . Reload that web page.
5. Open i → RENDER WITH BLENDER → RENDER → CONNECT; approve the native dialog.
   Select the DENOISE and ADAPTIVE settings, then press RENDER. Both default ON.
6. The browser shows the job's progress, elapsed time and final result. SHOW IN
   FOLDER reveals the PNG in Downloads / Drop & View Render. Rerenders receive
   numbered names. Additional camera snapshots queue while a render is running.

DENOISE enables OpenImageDenoise. ADAPTIVE enables adaptive sampling with a 0.03
noise threshold; sample count remains the requested maximum. With ADAPTIVE OFF,
the requested fixed sample count is used. Each accepted job freezes both flags.

No Allow Unsigned Extensions, Gatekeeper bypass or quarantine removal is needed
for a properly signed/notarized release. If macOS rejects a download, retain the
message and report it; do not disable system security.

If CONNECT reports an old/missing extension, quit the older Render app, check
Safari Extensions for the version from Applications, then reload the website.
Only one Render app should be running. Safari website access is user-controlled.

Manual .dvrender / GLB file opening remains available. Chrome/Edge setup is a
separate developer-mode flow in this version; browser store publication is not
part of the Safari release.
