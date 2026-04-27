param(
    [string]$GameVersion = "1.21.1",
    [string]$Loader = "neoforge",
    [string]$ClientModsFile = "$PSScriptRoot\..\client\client-mods.txt",
    [string]$OutFile = "$PSScriptRoot\modpack\manifest.json",
    [string]$ServerAddress = "95.105.73.172:25565",
    [string]$ManifestBaseUrl = "http://95.105.73.172:8088",
    [string]$NeoForgeVersion = "21.1.227"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ClientModsFile)) {
    throw "Client mods file not found: $ClientModsFile"
}

$outDir = Split-Path $OutFile -Parent
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$mods = Get-Content $ClientModsFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

$manifestMods = @()

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
        $manifestMods += [ordered]@{
            slug = $slug
            version_id = $match.id
            version_number = $match.version_number
            filename = $file.filename
            url = $file.url
            size = $file.size
            sha512 = $file.hashes.sha512
            sha1 = $file.hashes.sha1
        }
    }
}

$manifest = [ordered]@{
    pack = [ordered]@{
        name = "Create Aeronautics Pack"
        game_version = $GameVersion
        loader = $Loader
        generated_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        server_address = $ServerAddress
        manifest_base_url = $ManifestBaseUrl
    }
    launcher = [ordered]@{
        preferred = "hmcl"
        hmcl_version = "3.12.4"
        hmcl_download_url = "https://github.com/HMCL-dev/HMCL/releases/download/release-3.12.4/HMCL-3.12.4.exe"
    }
    neoforge = [ordered]@{
        version = $NeoForgeVersion
        installer_url = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-installer.jar"
    }
    mods = $manifestMods
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10

# Write UTF-8 without BOM so strict JSON parsers do not fail on a leading U+FEFF character.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $manifestJson, $utf8NoBom)
Write-Host "Manifest written: $OutFile"