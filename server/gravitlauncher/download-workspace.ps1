#!/usr/bin/env pwsh
# Downloads all GravitLauncher workspace files locally and packs them for upload to server
param(
    [string]$OutDir   = "$env:TEMP\gl_workspace",
    [string]$MirrorUrl = "https://mirror.gravitlauncher.com/5.7.x/workspace.json"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Fetching workspace.json..."
$ws = Invoke-RestMethod -Uri $MirrorUrl -UseBasicParsing

$downloads = [System.Collections.Generic.List[hashtable]]::new()

# Libraries (path + url entries)
foreach ($lib in $ws.libraries) {
    if ($lib.url -and $lib.path) {
        $downloads.Add(@{ path = $lib.path; url = $lib.url })
    } elseif ($lib.data -and $lib.path) {
        $fullPath = Join-Path $OutDir $lib.path.Replace('/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path $fullPath -Parent) | Out-Null
        [System.IO.File]::WriteAllText($fullPath, $lib.data, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  Created text: $($lib.path)"
    }
}

# multiMods — for NEOFORGE (filesystemfixer)
foreach ($name in $ws.multiMods.PSObject.Properties.Name) {
    $mod = $ws.multiMods.$name
    if ($mod.url -and $mod.target) {
        # target like "libraries/filesystemfixer.jar" → put under workdir/NEOFORGE/
        if ($mod.type -eq "NEOFORGE") {
            $downloads.Add(@{ path = "workdir/NEOFORGE/$($mod.target)"; url = $mod.url })
        }
    }
}

Write-Host "Downloading $($downloads.Count) files..."
$i = 0
foreach ($d in $downloads) {
    $i++
    $dest = Join-Path $OutDir $d.path.Replace('/', '\')
    if (Test-Path $dest) {
        Write-Host "  [$i/$($downloads.Count)] SKIP (exists): $($d.path)"
        continue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Write-Host "  [$i/$($downloads.Count)] $($d.path)"
    try {
        Invoke-WebRequest -Uri $d.url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Warning "  FAILED: $($d.url) — $_"
    }
}

Write-Host ""
Write-Host "Creating workspace.tar.gz..."
$tarOut = "$env:TEMP\gl_workspace.tar.gz"
Push-Location $OutDir
tar -czf $tarOut .
Pop-Location
Write-Host "Done: $tarOut ($([math]::Round((Get-Item $tarOut).Length/1KB)) KB)"
Write-Host ""
Write-Host "Upload and extract with:"
Write-Host "  scp $tarOut microvolk@10.14.0.113:/tmp/gl_workspace.tar.gz"
Write-Host "  ssh microvolk@10.14.0.113 'docker exec mc-gravitlauncher mkdir -p /app/data/config/MirrorHelper/workspace && docker cp /tmp/gl_workspace.tar.gz mc-gravitlauncher:/tmp/ && docker exec mc-gravitlauncher tar -xzf /tmp/gl_workspace.tar.gz -C /app/data/config/MirrorHelper/workspace/'"
