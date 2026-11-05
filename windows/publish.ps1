param([string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $PSScriptRoot 'artifacts'
$bundle = Join-Path $artifacts $Runtime
if (Test-Path $bundle) { Remove-Item $bundle -Recurse -Force }
New-Item $bundle -ItemType Directory -Force | Out-Null
foreach ($project in @('Tray', 'NativeHost')) {
    $output = Join-Path $artifacts "$project-$Runtime"
    & dotnet publish (Join-Path $PSScriptRoot "$project/DropViewRender.$project.csproj") -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -o $output
    if ($LASTEXITCODE -ne 0) { throw "Publishing $project failed" }
    Copy-Item "$output/*" $bundle -Recurse -Force
}
$resources = New-Item (Join-Path $bundle 'Resources') -ItemType Directory -Force
Copy-Item (Join-Path $repo 'DropViewRender/Resources/render_glb.py') $resources
Copy-Item (Join-Path $repo 'DropViewRender/Resources/backdrop.hdr') $resources
$extension = New-Item (Join-Path $bundle 'ChromiumExtension') -ItemType Directory -Force
Copy-Item (Join-Path $repo 'DropViewRender/ChromiumExtension/*') $extension
foreach ($name in @('content.js','protocol.js')) {
    Copy-Item (Join-Path $repo "DropViewRender/SafariExtension/Resources/$name") $extension
}
$manifest = Get-Content (Join-Path $extension 'manifest.json') -Raw | ConvertFrom-Json
$hash = [System.Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($manifest.key))
$id = -join ($hash[0..15] | ForEach-Object { [string][char](97 + ($_ -shr 4)) + [char](97 + ($_ -band 15)) })
[IO.File]::WriteAllText((Join-Path $bundle 'extension-id.txt'), $id, [Text.UTF8Encoding]::new($false))
Copy-Item (Join-Path $PSScriptRoot 'Register-Browsers.ps1') $bundle
Copy-Item (Join-Path $PSScriptRoot 'README.md') (Join-Path $bundle 'README-Windows.md')
Compress-Archive -Path "$bundle/*" -DestinationPath (Join-Path $artifacts "DropViewRender-$Runtime.zip") -Force
Write-Output "Bundle: $bundle"
