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

    Invoke-SSHCommand -SessionId $session.SessionId -Command "mkdir -p $RemoteDir/extras $RemoteDir/data $RemoteDir/modpack" | Out-Null

    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey -Path (Join-Path $serverRoot 'docker-compose.yml') -Destination "$RemoteDir/" -Force
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey -Path (Join-Path $serverRoot 'extras\server-mods.txt') -Destination "$RemoteDir/extras/" -Force
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey -Path (Join-Path $serverRoot 'modpack\manifest.json') -Destination "$RemoteDir/modpack/" -Force
    Set-SCPItem -ComputerName $RemoteHost -Credential $credential -KeyFile $KeyFile -AcceptKey -Path (Join-Path $serverRoot 'modpack\index.html') -Destination "$RemoteDir/modpack/" -Force

    Invoke-SSHCommand -SessionId $session.SessionId -Command "docker rm -f mc-create-aeronautics 2>/dev/null || true" | Out-Null
    Invoke-SSHCommand -SessionId $session.SessionId -Command "docker rm -f mc-modpack-http 2>/dev/null || true" | Out-Null
    $result = Invoke-SSHCommand -SessionId $session.SessionId -Command "cd $RemoteDir && docker compose up -d"
    $result.Output

    Invoke-SSHCommand -SessionId $session.SessionId -Command "cd $RemoteDir && docker compose ps && docker compose logs mc --tail 40 && docker compose logs modpack-http --tail 20"
}
finally {
    Remove-SSHSession -SSHSession $session | Out-Null
}