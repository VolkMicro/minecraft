param(
    [string]$ManifestUrl = "http://95.105.73.172:8088/manifest.json",
    [switch]$NoLauncherStart
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[AUTO-CLIENT] $Message"
}

function Get-FileSHA512 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Ensure-Java {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        Write-Step "Java already installed: $($java.Source)"
        return
    }

    Write-Step "Java not found. Installing Temurin 21 via winget..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget not found. Install App Installer from Microsoft Store and rerun."
    }

    $args = @(
        "install",
        "--id", "EclipseAdoptium.Temurin.21.JRE",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    )
    $proc = Start-Process -FilePath "winget" -ArgumentList $args -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        throw "Java install failed with exit code $($proc.ExitCode)"
    }
    Write-Step "Java installed"
}

function Ensure-NeoForge {
    param([pscustomobject]$Manifest)

    $mcRoot = Join-Path $env:APPDATA ".minecraft"
    $versionsDir = Join-Path $mcRoot "versions"
    $targetVersion = "neoforge-$($Manifest.neoforge.version)"
    $targetDir = Join-Path $versionsDir $targetVersion

    if (Test-Path $targetDir) {
        Write-Step "NeoForge already installed: $targetVersion"
        return
    }

    New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null
    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    $installerPath = Join-Path $tmpDir "neoforge-installer.jar"
    Write-Step "Downloading NeoForge installer"
    Invoke-WebRequest -Uri $Manifest.neoforge.installer_url -OutFile $installerPath

    Write-Step "Installing NeoForge client"
    $p1 = Start-Process -FilePath "java" -ArgumentList @("-jar", $installerPath, "--install-client") -Wait -PassThru
    if ($p1.ExitCode -ne 0) {
        $p2 = Start-Process -FilePath "java" -ArgumentList @("-jar", $installerPath, "--installClient") -Wait -PassThru
        if ($p2.ExitCode -ne 0) {
            throw "NeoForge installer failed: exit codes $($p1.ExitCode), $($p2.ExitCode)"
        }
    }

    Write-Step "NeoForge installed"
}

function Sync-Mods {
    param([pscustomobject]$Manifest)

    $modsDir = Join-Path $env:APPDATA ".minecraft\mods"
    New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

    $expected = @{}
    foreach ($m in $Manifest.mods) {
        $expected[$m.filename] = $m
    }

    Write-Step "Removing stale mods"
    Get-ChildItem $modsDir -Filter "*.jar" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $expected.ContainsKey($_.Name)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($m in $Manifest.mods) {
        $target = Join-Path $modsDir $m.filename
        $needDownload = $true

        if (Test-Path $target) {
            $hash = Get-FileSHA512 -Path $target
            if ($hash -eq $m.sha512) {
                $needDownload = $false
            }
        }

        if ($needDownload) {
            Write-Step "Downloading $($m.filename)"
            Invoke-WebRequest -Uri $m.url -OutFile $target
            $hash = Get-FileSHA512 -Path $target
            if ($hash -ne $m.sha512) {
                throw "Checksum mismatch after download: $($m.filename)"
            }
        }
    }

    Write-Step "Mods synced"
}

function Get-LauncherPath {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\TLauncher\TLauncher.exe",
        "$env:ProgramFiles\TLauncher\TLauncher.exe",
        "$env:ProgramFiles(x86)\TLauncher\TLauncher.exe",
        "$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\game\MinecraftLauncher.exe",
        "$env:ProgramFiles\Minecraft Launcher\MinecraftLauncher.exe",
        "$env:ProgramFiles(x86)\Minecraft Launcher\MinecraftLauncher.exe"
    )

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

Write-Step "Fetching manifest from $ManifestUrl"
$manifest = Invoke-RestMethod -Uri $ManifestUrl

Ensure-Java
Ensure-NeoForge -Manifest $manifest
Sync-Mods -Manifest $manifest

if (-not $NoLauncherStart) {
    $launcher = Get-LauncherPath
    if ($launcher) {
        Write-Step "Starting launcher: $launcher"
        Start-Process -FilePath $launcher | Out-Null
    }
    else {
        Write-Step "Launcher not found. Opening TLauncher download page"
        Start-Process "https://tlauncher.org/en/" | Out-Null
    }
}

Write-Step "Done. Server: $($manifest.pack.server_address)"