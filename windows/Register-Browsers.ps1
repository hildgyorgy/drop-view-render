$ErrorActionPreference = 'Stop'
$hostPath = Join-Path $PSScriptRoot 'DropViewRender.NativeHost.exe'
if (!(Test-Path $hostPath)) { throw 'Run the registration script from the extracted Windows bundle.' }
$id = (Get-Content (Join-Path $PSScriptRoot 'extension-id.txt') -Raw).Trim()
if ($id -notmatch '^[a-p]{32}$') { throw 'Invalid extension identity.' }
$manifestPath = Join-Path $PSScriptRoot 'native-host.json'
$manifest = @{ name = 'com.hildgyorgy.dropviewrender'; description = 'Drop & View Render'; type = 'stdio';
  path = $hostPath; allowed_origins = @("chrome-extension://$id/") } | ConvertTo-Json
[IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))
foreach ($browser in @('Google\Chrome','Microsoft\Edge')) {
    $key = "HKCU:\Software\$browser\NativeMessagingHosts\com.hildgyorgy.dropviewrender"
    New-Item $key -Force | Out-Null
    Set-Item $key -Value $manifestPath
}
Write-Output 'Native messaging registered. Enable the browser extension, then launch DropViewRender.Tray.exe.'
