param(
    [string]$HostName = "10.14.0.113",
    [int]$Port = 25565,
    [string]$RemoteUser = "microvolk",
    [string]$KeyFile = "$env:USERPROFILE\.ssh\id_ed25519"
)

$ErrorActionPreference = "Stop"

Write-Host "Checking TCP port $HostName:$Port"
Test-NetConnection $HostName -Port $Port -InformationLevel Detailed

if (Test-Path $KeyFile) {
    Import-Module Posh-SSH -ErrorAction Stop

    $credential = New-Object System.Management.Automation.PSCredential (
        $RemoteUser,
        (New-Object System.Security.SecureString)
    )

    $session = New-SSHSession -ComputerName $HostName -Credential $credential -KeyFile $KeyFile -AcceptKey

    try {
        Write-Host "Remote docker state"
        (Invoke-SSHCommand -SessionId $session.SessionId -Command 'docker ps --format "{{.Names}} | {{.Status}} | {{.Ports}}"').Output

        Write-Host "Recent remote logs"
        (Invoke-SSHCommand -SessionId $session.SessionId -Command 'docker logs mc-create-aeronautics --tail 60 2>&1').Output
    }
    finally {
        Remove-SSHSession -SSHSession $session | Out-Null
    }
}