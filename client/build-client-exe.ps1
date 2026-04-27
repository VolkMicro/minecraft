param(
    [string]$InputScript = "$PSScriptRoot\MinecraftAutoClient.ps1",
    [string]$OutExe      = "$PSScriptRoot\dist\MinecraftTechLauncher.exe",
    [string]$IconFile    = "$PSScriptRoot\icon.ico",
    [string]$Version     = "2.0.0"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InputScript)) {
    throw "Input script not found: $InputScript"
}

# Generate the icon
Write-Host "Generating icon..."
& "$PSScriptRoot\generate-icon.ps1" -OutPath $IconFile

New-Item -ItemType Directory -Force -Path (Split-Path $OutExe -Parent) | Out-Null

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -Force

$params = @{
    inputFile  = $InputScript
    outputFile = $OutExe
    noConsole  = $true
    title      = "Minecraft Tech Launcher"
    description = "Portable HMCL launcher for the Create Aeronautics pack"
    version    = $Version
    copyright  = "VolkMicro"
}

if (Test-Path $IconFile) {
    $params.iconFile = $IconFile
}

Invoke-ps2exe @params

Write-Host "Built: $OutExe  (v$Version)"