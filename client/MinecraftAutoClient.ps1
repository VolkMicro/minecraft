param(
    [string]$ManifestUrl = "http://95.105.73.172:8088/manifest.json",
    [switch]$NoLauncherStart
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-FileSHA512 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Ensure-Java {
    param(
        [object]$Reporter,
        [pscustomobject]$ProgressState
    )

    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        $Reporter.ReportProgress($ProgressState.Percent, [pscustomobject]@{
            status = "Java found"
            log = "Java already installed: $($java.Source)"
        })
        return
    }

    $Reporter.ReportProgress($ProgressState.Percent, [pscustomobject]@{
        status = "Installing Java"
        log = "Java not found. Installing Temurin 21 via winget..."
    })

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
}

function Ensure-NeoForge {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$Percent
    )

    $mcRoot = Join-Path $env:APPDATA ".minecraft"
    $versionsDir = Join-Path $mcRoot "versions"
    $targetVersion = "neoforge-$($Manifest.neoforge.version)"
    $targetDir = Join-Path $versionsDir $targetVersion

    if (Test-Path $targetDir) {
        $Reporter.ReportProgress($Percent, [pscustomobject]@{
            status = "NeoForge ready"
            log = "NeoForge already installed: $targetVersion"
        })
        return
    }

    New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null
    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    $installerPath = Join-Path $tmpDir "neoforge-installer.jar"
    $Reporter.ReportProgress($Percent, [pscustomobject]@{
        status = "Downloading NeoForge"
        log = "Downloading NeoForge installer: $($Manifest.neoforge.version)"
    })
    Invoke-WebRequest -Uri $Manifest.neoforge.installer_url -OutFile $installerPath

    $Reporter.ReportProgress($Percent, [pscustomobject]@{
        status = "Installing NeoForge"
        log = "Installing NeoForge client profile"
    })
    $p1 = Start-Process -FilePath "java" -ArgumentList @("-jar", $installerPath, "--install-client") -Wait -PassThru
    if ($p1.ExitCode -ne 0) {
        $p2 = Start-Process -FilePath "java" -ArgumentList @("-jar", $installerPath, "--installClient") -Wait -PassThru
        if ($p2.ExitCode -ne 0) {
            throw "NeoForge installer failed: exit codes $($p1.ExitCode), $($p2.ExitCode)"
        }
    }
}

function Sync-Mods {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$StartPercent,
        [int]$EndPercent
    )

    $modsDir = Join-Path $env:APPDATA ".minecraft\mods"
    New-Item -ItemType Directory -Force -Path $modsDir | Out-Null

    $expected = @{}
    foreach ($m in $Manifest.mods) {
        $expected[$m.filename] = $m
    }

    $Reporter.ReportProgress($StartPercent, [pscustomobject]@{
        status = "Preparing mods"
        log = "Removing old mods not present in current pack"
    })

    Get-ChildItem $modsDir -Filter "*.jar" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $expected.ContainsKey($_.Name)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $total = [Math]::Max(1, $Manifest.mods.Count)
    $idx = 0

    foreach ($m in $Manifest.mods) {
        $idx++
        $segment = [double]($EndPercent - $StartPercent)
        $pct = [int]($StartPercent + (($idx / $total) * $segment))

        $target = Join-Path $modsDir $m.filename
        $needDownload = $true

        if (Test-Path $target) {
            $hash = Get-FileSHA512 -Path $target
            if ($hash -eq $m.sha512) {
                $needDownload = $false
            }
        }

        if ($needDownload) {
            $Reporter.ReportProgress($pct, [pscustomobject]@{
                status = "Syncing mods ($idx/$total)"
                log = "Downloading $($m.filename)"
            })
            Invoke-WebRequest -Uri $m.url -OutFile $target
            $hash = Get-FileSHA512 -Path $target
            if ($hash -ne $m.sha512) {
                throw "Checksum mismatch after download: $($m.filename)"
            }
        }
        else {
            $Reporter.ReportProgress($pct, [pscustomobject]@{
                status = "Syncing mods ($idx/$total)"
                log = "Up-to-date: $($m.filename)"
            })
        }
    }
}

function Find-LauncherPath {
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

function Ensure-TLauncher {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$Percent
    )

    $launcher = Find-LauncherPath
    if ($launcher) {
        $Reporter.ReportProgress($Percent, [pscustomobject]@{
            status = "Launcher ready"
            log = "Launcher found: $launcher"
        })
        return $launcher
    }

    $url = $Manifest.launcher.tlauncher_installer_url
    if (-not $url) {
        return $null
    }

    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $installer = Join-Path $tmpDir "tlauncher-installer.exe"

    $Reporter.ReportProgress($Percent, [pscustomobject]@{
        status = "Installing launcher"
        log = "Downloading TLauncher installer"
    })
    Invoke-WebRequest -Uri $url -OutFile $installer

    $Reporter.ReportProgress($Percent, [pscustomobject]@{
        status = "Installing launcher"
        log = "Running TLauncher installer"
    })
    Start-Process -FilePath $installer -Wait

    return (Find-LauncherPath)
}

function New-LauncherUi {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Minecraft Tech Launcher"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(860, 610)
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(13, 18, 26)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Create Aeronautics | Tech Industrial Server"
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $title.Location = New-Object System.Drawing.Point(18, 14)
    $title.Size = New-Object System.Drawing.Size(760, 32)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "One click setup for kids and casual players: install, update, and play."
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $subtitle.Location = New-Object System.Drawing.Point(18, 48)
    $subtitle.Size = New-Object System.Drawing.Size(760, 22)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = "Server profile: tech progression, industrial automation, flying machines, shared exploration." 
    $desc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $desc.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $desc.Location = New-Object System.Drawing.Point(18, 72)
    $desc.Size = New-Object System.Drawing.Size(810, 20)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "Ready"
    $status.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $status.ForeColor = [System.Drawing.Color]::FromArgb(125, 211, 252)
    $status.Location = New-Object System.Drawing.Point(18, 105)
    $status.Size = New-Object System.Drawing.Size(810, 22)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(18, 132)
    $progress.Size = New-Object System.Drawing.Size(812, 24)
    $progress.Minimum = 0
    $progress.Maximum = 100

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ScrollBars = "Vertical"
    $log.ReadOnly = $true
    $log.Font = New-Object System.Drawing.Font("Consolas", 10)
    $log.BackColor = [System.Drawing.Color]::FromArgb(10, 14, 20)
    $log.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $log.BorderStyle = "FixedSingle"
    $log.Location = New-Object System.Drawing.Point(18, 170)
    $log.Size = New-Object System.Drawing.Size(812, 340)

    $playBtn = New-Object System.Windows.Forms.Button
    $playBtn.Text = "Prepare and Play"
    $playBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $playBtn.BackColor = [System.Drawing.Color]::FromArgb(14, 116, 144)
    $playBtn.ForeColor = [System.Drawing.Color]::White
    $playBtn.FlatStyle = "Flat"
    $playBtn.Location = New-Object System.Drawing.Point(18, 525)
    $playBtn.Size = New-Object System.Drawing.Size(190, 36)

    $recheckBtn = New-Object System.Windows.Forms.Button
    $recheckBtn.Text = "Update Only"
    $recheckBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $recheckBtn.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $recheckBtn.ForeColor = [System.Drawing.Color]::White
    $recheckBtn.FlatStyle = "Flat"
    $recheckBtn.Location = New-Object System.Drawing.Point(218, 525)
    $recheckBtn.Size = New-Object System.Drawing.Size(130, 36)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $closeBtn.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $closeBtn.ForeColor = [System.Drawing.Color]::White
    $closeBtn.FlatStyle = "Flat"
    $closeBtn.Location = New-Object System.Drawing.Point(720, 525)
    $closeBtn.Size = New-Object System.Drawing.Size(110, 36)
    $closeBtn.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@($title, $subtitle, $desc, $status, $progress, $log, $playBtn, $recheckBtn, $closeBtn))

    return [pscustomobject]@{
        Form = $form
        Status = $status
        Progress = $progress
        Log = $log
        PlayButton = $playBtn
        UpdateButton = $recheckBtn
    }
}

function Add-LogLine {
    param(
        [System.Windows.Forms.TextBox]$Log,
        [string]$Message
    )
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $Log.AppendText($line + [Environment]::NewLine)
    $Log.SelectionStart = $Log.Text.Length
    $Log.ScrollToCaret()
}

$ui = New-LauncherUi

$worker = New-Object System.ComponentModel.BackgroundWorker
$worker.WorkerReportsProgress = $true

$worker.Add_DoWork({
    param($sender, $e)

    $updateOnly = [bool]$e.Argument

    $sender.ReportProgress(5, [pscustomobject]@{ status = "Fetching manifest"; log = "Fetching manifest from $ManifestUrl" })
    $manifest = Invoke-RestMethod -Uri $ManifestUrl

    $sender.ReportProgress(15, [pscustomobject]@{ status = "Checking Java"; log = "Checking Java runtime" })
    Ensure-Java -Reporter $sender -ProgressState ([pscustomobject]@{ Percent = 20 })

    $sender.ReportProgress(30, [pscustomobject]@{ status = "Checking NeoForge"; log = "Checking NeoForge client profile" })
    Ensure-NeoForge -Manifest $manifest -Reporter $sender -Percent 35

    $sender.ReportProgress(45, [pscustomobject]@{ status = "Syncing mods"; log = "Comparing local mods with server manifest" })
    Sync-Mods -Manifest $manifest -Reporter $sender -StartPercent 45 -EndPercent 88

    if (-not $updateOnly -and -not $NoLauncherStart) {
        $sender.ReportProgress(92, [pscustomobject]@{ status = "Preparing launcher"; log = "Looking for launcher" })
        $launcher = Ensure-TLauncher -Manifest $manifest -Reporter $sender -Percent 94

        if ($launcher) {
            Start-Process -FilePath $launcher | Out-Null
            $sender.ReportProgress(100, [pscustomobject]@{ status = "Ready"; log = "Launcher started: $launcher" })
        }
        else {
            Start-Process "https://tlauncher.org/en/" | Out-Null
            $sender.ReportProgress(100, [pscustomobject]@{ status = "Launcher needed"; log = "Launcher not found after install attempt. Opened TLauncher site." })
        }
    }
    else {
        $sender.ReportProgress(100, [pscustomobject]@{ status = "Updated"; log = "Client files are up to date" })
    }

    $e.Result = $manifest
})

$worker.Add_ProgressChanged({
    param($sender, $e)

    $ui.Progress.Value = [Math]::Min(100, [Math]::Max(0, $e.ProgressPercentage))
    if ($e.UserState) {
        if ($e.UserState.status) {
            $ui.Status.Text = $e.UserState.status
        }
        if ($e.UserState.log) {
            Add-LogLine -Log $ui.Log -Message $e.UserState.log
        }
    }
})

$worker.Add_RunWorkerCompleted({
    param($sender, $e)

    $ui.PlayButton.Enabled = $true
    $ui.UpdateButton.Enabled = $true

    if ($e.Error) {
        $ui.Status.Text = "Failed"
        $ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
        Add-LogLine -Log $ui.Log -Message ("ERROR: " + $e.Error.Exception.Message)
        return
    }

    $m = $e.Result
    $server = if ($m -and $m.pack) { $m.pack.server_address } else { "unknown" }
    $ui.Status.Text = "Done"
    $ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(134, 239, 172)
    Add-LogLine -Log $ui.Log -Message "Done. Server: $server"
})

function Start-ClientFlow {
    param([bool]$UpdateOnly)
    if ($worker.IsBusy) { return }
    $ui.PlayButton.Enabled = $false
    $ui.UpdateButton.Enabled = $false
    $ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(125, 211, 252)
    $ui.Progress.Value = 0
    Add-LogLine -Log $ui.Log -Message "Starting flow (updateOnly=$UpdateOnly)"
    $worker.RunWorkerAsync($UpdateOnly)
}

$ui.PlayButton.Add_Click({ Start-ClientFlow -UpdateOnly:$false })
$ui.UpdateButton.Add_Click({ Start-ClientFlow -UpdateOnly:$true })

$ui.Form.Add_Shown({ Start-ClientFlow -UpdateOnly:$false })

[void]$ui.Form.ShowDialog()