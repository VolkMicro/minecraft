param(
    [string]$InputScript = "$PSScriptRoot\MinecraftAutoClient.ps1",
    [string]$OutExe = "$PSScriptRoot\dist\MinecraftAutoClient.exe"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $InputScript)) {
    throw "Input script not found: $InputScript"
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutExe -Parent) | Out-Null

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -Force

Invoke-ps2exe -inputFile $InputScript -outputFile $OutExe -noConsole -title "Minecraft Auto Client"

Write-Host "Built: $OutExe"