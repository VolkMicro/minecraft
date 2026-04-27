param(
    [string]$ManifestUrl  = "http://95.105.73.172:8088/manifest.json",
    [string]$ServerStatus = "https://api.mcsrvstat.us/3/95.105.73.172:25565",
    [string]$LauncherVersion = "1.2.0",
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

function Invoke-ReporterProgress {
    param(
        [object]$Reporter,
        [int]$Percent,
        [object]$State
    )

    if ($Reporter -and $Reporter.PSObject.Properties['ReportProgress']) {
        $reportProgress = $Reporter.PSObject.Properties['ReportProgress'].Value
        if ($reportProgress -is [scriptblock]) {
            & $reportProgress $Percent $State
            return
        }
    }

    if ($Reporter -and $Reporter -is [System.ComponentModel.BackgroundWorker]) {
        $Reporter.ReportProgress($Percent, $State)
        return
    }

    throw 'Reporter does not support progress updates.'
}

function Ensure-Java {
    param(
        [object]$Reporter,
        [pscustomobject]$ProgressState
    )

    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) {
        Invoke-ReporterProgress -Reporter $Reporter -Percent $ProgressState.Percent -State ([pscustomobject]@{
            status = "Java found"
            log = "Java already installed: $($java.Source)"
        })
        return
    }

    Invoke-ReporterProgress -Reporter $Reporter -Percent $ProgressState.Percent -State ([pscustomobject]@{
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
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "NeoForge ready"
            log = "NeoForge already installed: $targetVersion"
        })
        return
    }

    New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null
    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    $installerPath = Join-Path $tmpDir "neoforge-installer.jar"
    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Downloading NeoForge"
        log = "Downloading NeoForge installer: $($Manifest.neoforge.version)"
    })
    Invoke-WebRequest -Uri $Manifest.neoforge.installer_url -OutFile $installerPath

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
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

    Invoke-ReporterProgress -Reporter $Reporter -Percent $StartPercent -State ([pscustomobject]@{
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
            Invoke-ReporterProgress -Reporter $Reporter -Percent $pct -State ([pscustomobject]@{
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
            Invoke-ReporterProgress -Reporter $Reporter -Percent $pct -State ([pscustomobject]@{
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
        "$env:ProgramFiles(x86)\TLauncher\TLauncher.exe"
    )

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-UnsupportedOfficialLauncherPath {
    $candidates = @(
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
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "Launcher ready"
            log = "Launcher found: $launcher"
        })
        return $launcher
    }

    $officialLauncher = Find-UnsupportedOfficialLauncherPath
    if ($officialLauncher) {
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "Selecting launcher"
            log = "Official Minecraft Launcher detected but ignored: $officialLauncher"
        })
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "Selecting launcher"
            log = "Reason: it pulls vanilla/default versions and does not reliably launch this NeoForge pack."
        })
    }

    $url = $Manifest.launcher.tlauncher_installer_url
    if (-not $url) {
        return $null
    }

    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $installer = Join-Path $tmpDir "tlauncher-installer.exe"

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Installing launcher"
        log = "Downloading TLauncher installer"
    })
    Invoke-WebRequest -Uri $url -OutFile $installer

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Installing launcher"
        log = "Running TLauncher installer"
    })
    Start-Process -FilePath $installer -Wait

    return (Find-LauncherPath)
}

function New-UiReporter {
    return [pscustomobject]@{
        ReportProgress = {
            param([int]$Percent, [object]$State)

            $script:ui.Progress.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
            if ($State) {
                if ($State.status) {
                    $script:ui.Status.Text = $State.status
                }
                if ($State.log) {
                    Add-LogLine -Log $script:ui.Log -Message $State.log
                }
            }

            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# --- Colour palette ----------------------------------
$C = @{
    Bg         = [System.Drawing.Color]::FromArgb(10, 14, 22)
    HeaderTop  = [System.Drawing.Color]::FromArgb(8,  18, 35)
    HeaderBot  = [System.Drawing.Color]::FromArgb(14, 30, 55)
    Accent     = [System.Drawing.Color]::FromArgb(14, 165, 233)
    AccentDark = [System.Drawing.Color]::FromArgb(7,  89, 133)
    TextPrim   = [System.Drawing.Color]::FromArgb(226, 232, 240)
    TextMuted  = [System.Drawing.Color]::FromArgb(100, 116, 139)
    TextGreen  = [System.Drawing.Color]::FromArgb(74,  222, 128)
    TextRed    = [System.Drawing.Color]::FromArgb(248, 113, 113)
    TextYellow = [System.Drawing.Color]::FromArgb(234, 179,   8)
    Panel      = [System.Drawing.Color]::FromArgb(15,  23,  42)
    LogBg      = [System.Drawing.Color]::FromArgb( 7,  12,  20)
    BtnSub     = [System.Drawing.Color]::FromArgb(30,  41,  59)
}

# --- Generate server banner image via GDI+ -----------
function New-BannerBitmap {
    $W = 860; $H = 110
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    # Background gradient
    $gbrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Rectangle(0,0,$W,$H)),
        [System.Drawing.Color]::FromArgb(8, 18, 38),
        [System.Drawing.Color]::FromArgb(16, 32, 62),
        [System.Drawing.Drawing2D.LinearGradientMode]::BackwardDiagonal)
    $g.FillRectangle($gbrush, 0, 0, $W, $H)
    $gbrush.Dispose()

    # Decorative diagonal stripes (subtle)
    $stripePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(12, 100, 180, 255))
    $stripePen.Width = 1.0
    for ($x = -$H; $x -lt $W; $x += 36) {
        $g.DrawLine($stripePen, $x, 0, $x + $H, $H)
    }
    $stripePen.Dispose()

    # Accent bottom border line
    $accentPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(14, 165, 233))
    $accentPen.Width = 2.0
    $g.DrawLine($accentPen, 0, $H - 2, $W, $H - 2)
    $accentPen.Dispose()

    # Left colour bar
    $barBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14, 165, 233))
    $g.FillRectangle($barBrush, 0, 0, 4, $H)
    $barBrush.Dispose()

    # Title text
    $fontTitle = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $brushTitle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 248, 255))
    $g.DrawString("Create Aeronautics  -  Tech Industrial Server", $fontTitle, $brushTitle, 18, 12)
    $fontTitle.Dispose(); $brushTitle.Dispose()

    # Subtitle text
    $fontSub = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $brushSub = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(148, 163, 184))
    $g.DrawString("NeoForge 1.21.1  -  Industrial automation, flying machines, tech progression, shared exploration", $fontSub, $brushSub, 18, 54)
    $fontSub.Dispose(); $brushSub.Dispose()

    # Version label bottom-right
    $fontVer = New-Object System.Drawing.Font("Segoe UI", 8)
    $brushVer = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(71, 85, 105))
    $verStr = "Launcher v$LauncherVersion"
    $sz = $g.MeasureString($verStr, $fontVer)
    $g.DrawString($verStr, $fontVer, $brushVer, ($W - $sz.Width - 10), ($H - $sz.Height - 6))
    $fontVer.Dispose(); $brushVer.Dispose()

    $g.Dispose()
    return $bmp
}

# --- Build the main form ------------------------------
function New-LauncherUi {

    $form = New-Object System.Windows.Forms.Form
    $form.Text              = "Minecraft Tech Launcher  v$LauncherVersion"
    $form.StartPosition     = "CenterScreen"
    $form.Size              = New-Object System.Drawing.Size(880, 660)
    $form.FormBorderStyle   = "FixedSingle"
    $form.MaximizeBox       = $false
    $form.BackColor         = $C.Bg

    # -- Banner PictureBox --
    $banner = New-Object System.Windows.Forms.PictureBox
    $banner.Location        = New-Object System.Drawing.Point(0, 0)
    $banner.Size            = New-Object System.Drawing.Size(880, 110)
    $banner.SizeMode        = "StretchImage"
    $banner.Image           = New-BannerBitmap
    $form.Controls.Add($banner)

    # -- Server status row --
    $srvPanel = New-Object System.Windows.Forms.Panel
    $srvPanel.Location      = New-Object System.Drawing.Point(0, 110)
    $srvPanel.Size          = New-Object System.Drawing.Size(880, 36)
    $srvPanel.BackColor     = $C.Panel

    $srvDot = New-Object System.Windows.Forms.Panel
    $srvDot.BackColor       = $C.TextMuted
    $srvDot.Location        = New-Object System.Drawing.Point(16, 12)
    $srvDot.Size            = New-Object System.Drawing.Size(10, 10)

    $srvLabel = New-Object System.Windows.Forms.Label
    $srvLabel.Text          = "Server: checking..."
    $srvLabel.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $srvLabel.ForeColor     = $C.TextMuted
    $srvLabel.Location      = New-Object System.Drawing.Point(34, 9)
    $srvLabel.Size          = New-Object System.Drawing.Size(400, 18)

    $srvRefreshBtn = New-Object System.Windows.Forms.Button
    $srvRefreshBtn.Text     = "Refresh"
    $srvRefreshBtn.Font     = New-Object System.Drawing.Font("Segoe UI", 10)
    $srvRefreshBtn.FlatStyle = "Flat"
    $srvRefreshBtn.FlatAppearance.BorderSize = 0
    $srvRefreshBtn.BackColor = $C.Panel
    $srvRefreshBtn.ForeColor = $C.TextMuted
    $srvRefreshBtn.Location  = New-Object System.Drawing.Point(450, 4)
    $srvRefreshBtn.Size      = New-Object System.Drawing.Size(78, 28)

    $srvPanel.Controls.AddRange(@($srvDot, $srvLabel, $srvRefreshBtn))
    $form.Controls.Add($srvPanel)

    # -- Status + progress --
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text       = "Ready"
    $statusLabel.Font       = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $statusLabel.ForeColor  = $C.Accent
    $statusLabel.Location   = New-Object System.Drawing.Point(14, 155)
    $statusLabel.Size       = New-Object System.Drawing.Size(700, 20)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location      = New-Object System.Drawing.Point(14, 178)
    $progress.Size          = New-Object System.Drawing.Size(848, 20)
    $progress.Minimum       = 0
    $progress.Maximum       = 100

    # -- Log box --
    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline          = $true
    $log.ScrollBars         = "Vertical"
    $log.ReadOnly           = $true
    $log.Font               = New-Object System.Drawing.Font("Consolas", 9.5)
    $log.BackColor          = $C.LogBg
    $log.ForeColor          = $C.TextPrim
    $log.BorderStyle        = "FixedSingle"
    $log.Location           = New-Object System.Drawing.Point(14, 206)
    $log.Size               = New-Object System.Drawing.Size(848, 360)

    # -- Settings row --
    $ramLabel = New-Object System.Windows.Forms.Label
    $ramLabel.Text          = "RAM:"
    $ramLabel.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $ramLabel.ForeColor     = $C.TextMuted
    $ramLabel.Location      = New-Object System.Drawing.Point(14, 580)
    $ramLabel.Size          = New-Object System.Drawing.Size(36, 24)

    $ramCombo = New-Object System.Windows.Forms.ComboBox
    $ramCombo.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $ramCombo.FlatStyle     = "Flat"
    $ramCombo.BackColor     = $C.BtnSub
    $ramCombo.ForeColor     = $C.TextPrim
    $ramCombo.DropDownStyle = "DropDownList"
    $ramCombo.Location      = New-Object System.Drawing.Point(52, 576)
    $ramCombo.Size          = New-Object System.Drawing.Size(90, 26)
    @("2 GB","3 GB","4 GB","6 GB","8 GB","12 GB","16 GB") | ForEach-Object { [void]$ramCombo.Items.Add($_) }
    $ramCombo.SelectedIndex = 2  # default 4 GB

    # -- Buttons --
    $playBtn = New-Object System.Windows.Forms.Button
    $playBtn.Text           = "Play"
    $playBtn.Font           = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $playBtn.BackColor      = $C.AccentDark
    $playBtn.ForeColor      = [System.Drawing.Color]::White
    $playBtn.FlatStyle      = "Flat"
    $playBtn.FlatAppearance.BorderColor = $C.Accent
    $playBtn.Location       = New-Object System.Drawing.Point(14, 574)
    $playBtn.Size           = New-Object System.Drawing.Size(0, 36)  # hidden width until RAM moves
    $playBtn.Location       = New-Object System.Drawing.Point(154, 574)
    $playBtn.Size           = New-Object System.Drawing.Size(160, 36)

    $updateBtn = New-Object System.Windows.Forms.Button
    $updateBtn.Text         = "Update Only"
    $updateBtn.Font         = New-Object System.Drawing.Font("Segoe UI", 9)
    $updateBtn.BackColor    = $C.BtnSub
    $updateBtn.ForeColor    = $C.TextPrim
    $updateBtn.FlatStyle    = "Flat"
    $updateBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $updateBtn.Location     = New-Object System.Drawing.Point(324, 574)
    $updateBtn.Size         = New-Object System.Drawing.Size(140, 36)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text          = "Close"
    $closeBtn.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $closeBtn.BackColor     = $C.Bg
    $closeBtn.ForeColor     = $C.TextMuted
    $closeBtn.FlatStyle     = "Flat"
    $closeBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $closeBtn.Location      = New-Object System.Drawing.Point(754, 574)
    $closeBtn.Size          = New-Object System.Drawing.Size(108, 36)
    $closeBtn.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@($statusLabel, $progress, $log, $ramLabel, $ramCombo, $playBtn, $updateBtn, $closeBtn))

    return [pscustomobject]@{
        Form         = $form
        SrvDot       = $srvDot
        SrvLabel     = $srvLabel
        SrvRefresh   = $srvRefreshBtn
        Status       = $statusLabel
        Progress     = $progress
        Log          = $log
        RamCombo     = $ramCombo
        PlayButton   = $playBtn
        UpdateButton = $updateBtn
    }
}

function Add-LogLine {
    param([System.Windows.Forms.TextBox]$Log, [string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $Log.AppendText($line + [Environment]::NewLine)
    $Log.SelectionStart = $Log.Text.Length
    $Log.ScrollToCaret()
}

# --- Server status async check ------------------------
function Update-ServerStatus {
    $dot   = $script:ui.SrvDot
    $label = $script:ui.SrvLabel

    try {
        $r = Invoke-RestMethod -Uri $script:ServerStatus -TimeoutSec 6 -ErrorAction Stop
    }
    catch {
        $r = $null
    }

    if ($r -and $r.online) {
        $players = "$($r.players.online)/$($r.players.max)"
        $dot.BackColor   = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $label.Text      = "95.105.73.172  -  Online  -  $players players"
    }
    else {
        $dot.BackColor   = [System.Drawing.Color]::FromArgb(248, 113, 113)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $label.Text      = "95.105.73.172  -  Offline"
    }
}

# --- RAM string helper --------------------------------
function Get-RamXmx {
    param([string]$Selected)
    $map = @{
        "2 GB"  = "2048m"
        "3 GB"  = "3072m"
        "4 GB"  = "4096m"
        "6 GB"  = "6144m"
        "8 GB"  = "8192m"
        "12 GB" = "12288m"
        "16 GB" = "16384m"
    }
    $v = $map[$Selected]
    return if ($v) { $v } else { "4096m" }
}

$ui = New-LauncherUi

# --- Server status timer (auto-refresh every 60 s) ---
$srvTimer = New-Object System.Windows.Forms.Timer
$srvTimer.Interval = 60000
$srvTimer.Add_Tick({ Update-ServerStatus })
$ui.SrvRefresh.Add_Click({ Update-ServerStatus })

function Invoke-ClientFlow {
    param([bool]$UpdateOnly)

    $reporter = New-UiReporter
    $manifest = $null

    try {
        & $reporter.ReportProgress 5 ([pscustomobject]@{ status = "Fetching manifest"; log = "Fetching manifest from $script:ManifestUrl" })
        $manifest = Invoke-RestMethod -Uri $script:ManifestUrl

        & $reporter.ReportProgress 15 ([pscustomobject]@{ status = "Checking Java"; log = "Checking Java runtime" })
        Ensure-Java -Reporter $reporter -ProgressState ([pscustomobject]@{ Percent = 20 })

        & $reporter.ReportProgress 30 ([pscustomobject]@{ status = "Checking NeoForge"; log = "Checking NeoForge client profile" })
        Ensure-NeoForge -Manifest $manifest -Reporter $reporter -Percent 35

        & $reporter.ReportProgress 45 ([pscustomobject]@{ status = "Syncing mods"; log = "Comparing local mods with server manifest" })
        Sync-Mods -Manifest $manifest -Reporter $reporter -StartPercent 45 -EndPercent 88

        if (-not $UpdateOnly -and -not $script:NoLauncherStart) {
            & $reporter.ReportProgress 92 ([pscustomobject]@{ status = "Preparing launcher"; log = "Looking for launcher" })
            $launcher = Ensure-TLauncher -Manifest $manifest -Reporter $reporter -Percent 94

            if ($launcher) {
                $xmx = Get-RamXmx -Selected $script:ui.RamCombo.SelectedItem
                & $reporter.ReportProgress 98 ([pscustomobject]@{ status = "Launching"; log = "Starting launcher (RAM: $xmx)" })
                Start-Process -FilePath $launcher | Out-Null
                & $reporter.ReportProgress 100 ([pscustomobject]@{ status = "Launcher started"; log = "Done." })
            }
            else {
                Start-Process "https://tlauncher.org/en/" | Out-Null
                & $reporter.ReportProgress 100 ([pscustomobject]@{ status = "Launcher needed"; log = "Launcher not found - opened TLauncher site." })
            }
        }
        else {
            & $reporter.ReportProgress 100 ([pscustomobject]@{ status = "Up to date"; log = "All client files match the server manifest." })
        }

        $server = if ($manifest -and $manifest.pack) { $manifest.pack.server_address } else { "unknown" }
        $script:ui.Status.Text = "Ready  -  Server: $server"
        $script:ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        Add-LogLine -Log $script:ui.Log -Message ("All done. Server address: $server")
    }
    catch {
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $script:ui.Status.Text = "Failed"
        $script:ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
        Add-LogLine -Log $script:ui.Log -Message ("ERROR: " + $message)
    }
    finally {
        $script:ui.PlayButton.Enabled = $true
        $script:ui.UpdateButton.Enabled = $true
    }
}

function Start-ClientFlow {
    param([bool]$UpdateOnly)
    $script:ui.PlayButton.Enabled   = $false
    $script:ui.UpdateButton.Enabled = $false
    $script:ui.Status.ForeColor     = [System.Drawing.Color]::FromArgb(14, 165, 233)
    $script:ui.Progress.Value       = 0
    Add-LogLine -Log $script:ui.Log -Message "--- Starting $(if ($UpdateOnly) { 'update' } else { 'full setup' }) ---"
    Invoke-ClientFlow -UpdateOnly:$UpdateOnly
}

$ui.PlayButton.Add_Click({   Start-ClientFlow -UpdateOnly:$false })
$ui.UpdateButton.Add_Click({ Start-ClientFlow -UpdateOnly:$true  })

$ui.Form.Add_Shown({
    $srvTimer.Start()
    Update-ServerStatus
    $script:ui.Status.Text = "Ready"
    Add-LogLine -Log $script:ui.Log -Message "Launcher ready. Click Play to install and start, or Update Only to sync files."
})

[void]$ui.Form.ShowDialog()
$srvTimer.Stop()
