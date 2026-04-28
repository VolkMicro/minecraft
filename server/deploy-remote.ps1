param(
    [string]$RemoteHost = "10.14.0.113",
    [string]$RemoteUser = "microvolk",
    [string]$RemoteDir = "~/infra",
    [string]$KeyFile = "$env:USERPROFILE\.ssh\id_ed25519",
    [string]$ServerAddress = "95.105.73.172:25565",
    [string]$ManifestBaseUrl = "http://95.105.73.172:8088"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $KeyFile)) {
    throw "SSH key not found: $KeyFile"
}

Import-Module Posh-SSH -ErrorAction Stop

& "$PSScriptRoot\generate-modpack-manifest.ps1" -ServerAddress $ServerAddress -ManifestBaseUrl $ManifestBaseUrl

$credential = New-Object System.Management.Automation.PSCredential (
    $RemoteUser,
    (New-Object System.Security.SecureString)
)

$session = New-SSHSession -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey

try {
    $serverRoot = $PSScriptRoot

    Invoke-SSHCommand -SessionId $session.SessionId -Command `
        "mkdir -p $RemoteDir/extras $RemoteDir/data $RemoteDir/modpack $RemoteDir/gravitlauncher/data" | Out-Null

    # Core compose config
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'docker-compose.yml') -Destination "$RemoteDir/" -Force

    # MC server extras
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'extras\server-mods.txt') -Destination "$RemoteDir/extras/" -Force

    # Modpack HTTP (kept for legacy clients)
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'modpack\manifest.json') -Destination "$RemoteDir/modpack/" -Force
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'modpack\index.html') -Destination "$RemoteDir/modpack/" -Force

    # GravitLauncher nginx config + setup script
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'gravitlauncher\nginx.conf') -Destination "$RemoteDir/gravitlauncher/" -Force
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey `
        -Path (Join-Path $serverRoot 'gravitlauncher\setup-launchserver.sh') -Destination "$RemoteDir/gravitlauncher/" -Force
    Invoke-SSHCommand -SessionId $session.SessionId -Command `
        "chmod +x $RemoteDir/gravitlauncher/setup-launchserver.sh" | Out-Null

    # Restart MC + nginx-gl (keep gravitlauncher running to preserve LaunchServer state)
    Invoke-SSHCommand -SessionId $session.SessionId -Command "docker rm -f mc-create-aeronautics 2>/dev/null || true" | Out-Null
    Invoke-SSHCommand -SessionId $session.SessionId -Command "docker rm -f mc-modpack-http 2>/dev/null || true" | Out-Null
    Invoke-SSHCommand -SessionId $session.SessionId -Command "docker rm -f mc-gravitlauncher-nginx 2>/dev/null || true" | Out-Null
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command "cd $RemoteDir && docker compose up -d"
    $result.Output

    Write-Host ""
    Write-Host "=== Container status ==="
    $status = Invoke-SSHCommand -SessionId $session.SessionId -Command "cd $RemoteDir && docker compose ps"
    $status.Output

    Write-Host ""
    Write-Host "=== MC server logs (last 20) ==="
    $logs = Invoke-SSHCommand -SessionId $session.SessionId -Command "cd $RemoteDir && docker compose logs mc --tail 20"
    $logs.Output

    Write-Host ""
    Write-Host "================================================================"
    Write-Host "  GravitLauncher nginx is up at http://idiot-home.ru:7240"
    Write-Host ""
    Write-Host "  If this is a FIRST DEPLOY, run on the server:"
    Write-Host "    cd $RemoteDir && bash gravitlauncher/setup-launchserver.sh"
    Write-Host ""
    Write-Host "  Launcher.exe will be at:"
    Write-Host "    http://idiot-home.ru:7240/Launcher.exe"
    Write-Host "================================================================"
}
finally {
    Remove-SSHSession -SSHSession $session | Out-Null
}