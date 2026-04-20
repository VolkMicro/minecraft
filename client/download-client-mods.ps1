param(
    [string]$GameVersion = "1.21.1",
    [string]$Loader = "neoforge",
    [string]$ModsFile = "$PSScriptRoot\client-mods.txt",
    [string]$OutputDir = "$env:APPDATA\.minecraft\mods"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ModsFile)) {
    throw "Mods file not found: $ModsFile"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Clean stale Embeddium jars to avoid Veil compatibility errors on NeoForge 1.21.1.
Get-ChildItem -Path $OutputDir -Filter "embeddium*.jar" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$mods = Get-Content $ModsFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

foreach ($slug in $mods) {
    Write-Host "Resolving $slug for $GameVersion/$Loader"
    $versions = Invoke-RestMethod "https://api.modrinth.com/v2/project/$slug/version"
    $match = $versions |
        Where-Object { $_.game_versions -contains $GameVersion -and $_.loaders -contains $Loader } |
        Sort-Object date_published -Descending |
        Select-Object -First 1

    if (-not $match) {
        throw "No compatible version found for $slug"
    }

    foreach ($file in $match.files) {
        $target = Join-Path $OutputDir $file.filename
        Write-Host "Downloading $($file.filename)"
        Invoke-WebRequest $file.url -OutFile $target
    }
}

Write-Host "Client mods downloaded to $OutputDir"