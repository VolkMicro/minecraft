param(
    [string]$LaunchServerUrl = "http://idiot-home.ru:7240",
    [string]$LauncherVersion = "3.0.0",
    [switch]$NoLauncherStart
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppRoot      = Join-Path $env:LOCALAPPDATA "MinecraftTechLauncher"
$script:LauncherJar  = Join-Path $script:AppRoot "GravitLauncher.jar"
$script:RuntimeDir   = Join-Path $script:AppRoot "runtime"
$script:VersionFile  = Join-Path $script:AppRoot "launcher-version.txt"

# ─────────────────────────────────────────────────────────────────────────────
# UI
# ─────────────────────────────────────────────────────────────────────────────
function Build-UI {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Create Aeronautics — Launcher v$LauncherVersion"
    $form.Size = New-Object System.Drawing.Size(480, 220)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Подготовка лаунчера..."
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $lbl.Size = New-Object System.Drawing.Size(430, 24)
    $form.Controls.Add($lbl)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(20, 55)
    $bar.Size = New-Object System.Drawing.Size(430, 22)
    $bar.Style = "Continuous"
    $bar.Minimum = 0
    $bar.Maximum = 100
    $form.Controls.Add($bar)

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Location = New-Object System.Drawing.Point(20, 90)
    $log.Size = New-Object System.Drawing.Size(430, 80)
    $log.ReadOnly = $true
    $log.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $log.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    $log.Font = New-Object System.Drawing.Font("Consolas", 8)
    $log.ScrollBars = "Vertical"
    $form.Controls.Add($log)

    return [pscustomobject]@{ Form = $form; Label = $lbl; Bar = $bar; Log = $log }
}

function Write-Log {
    param([string]$Message, [int]$Percent = -1)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $line = "[$ts] $Message"
    Write-Host $line
    if ($script:ui) {
        $msg = $Message; $pct = $Percent; $ln = $line
        $script:ui.Form.BeginInvoke([Action]{
            $script:ui.Label.Text = $msg
            if ($pct -ge 0) { $script:ui.Bar.Value = [Math]::Min(100, $pct) }
            $script:ui.Log.AppendText($ln + "`n")
            $script:ui.Log.ScrollToCaret()
        })
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Download with retry
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Download {
    param([string]$Uri, [string]$OutFile, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            if ($i -eq $Retries) { throw "Не удалось скачать ${Uri} после ${Retries} попыток: $_" }
            Start-Sleep -Seconds 3
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main bootstrap
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Bootstrap {
    New-Item -ItemType Directory -Force -Path $script:AppRoot | Out-Null

    # ── 1. Проверяем версию лаунчера ─────────────────────────────────────────
    Write-Log "Проверяем версию лаунчера на сервере..." 10
    $serverVersion = $null
    try {
        $info = Invoke-RestMethod -Uri "$LaunchServerUrl/api/launcher/info" -TimeoutSec 10 -ErrorAction SilentlyContinue
        $serverVersion = $info.launcherVersion
    } catch {}

    $localVersion = if (Test-Path $script:VersionFile) {
        (Get-Content $script:VersionFile -Raw).Trim()
    } else { "" }

    $needDownload = (-not (Test-Path $script:LauncherJar)) -or
                    ($serverVersion -and $localVersion -ne $serverVersion)

    if ($needDownload) {
        Write-Log "Скачиваем GravitLauncher.jar с сервера..." 20
        Invoke-Download -Uri "$LaunchServerUrl/Launcher.jar" -OutFile $script:LauncherJar
        if ($serverVersion) {
            [System.IO.File]::WriteAllText($script:VersionFile, $serverVersion,
                [System.Text.UTF8Encoding]::new($false))
        }
        Write-Log "GravitLauncher.jar загружен." 45
    } else {
        Write-Log "GravitLauncher.jar актуален." 45
    }

    # ── 2. Java runtime с JavaFX ─────────────────────────────────────────────
    $javaExe = Join-Path $script:RuntimeDir "bin\java.exe"
    if (-not (Test-Path $javaExe)) {
        Write-Log "Скачиваем Java runtime (~94 МБ, первый запуск)..." 50
        $runtimeZip = Join-Path $env:TEMP "gl-runtime.zip"
        Invoke-Download -Uri "$LaunchServerUrl/runtime.zip" -OutFile $runtimeZip
        Write-Log "Распаковываем Java runtime..." 75
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $tmpExtract = Join-Path $env:TEMP "gl-runtime-extract"
        if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($runtimeZip, $tmpExtract)
        $innerDir = Get-ChildItem $tmpExtract | Select-Object -First 1
        if (Test-Path $script:RuntimeDir) { Remove-Item $script:RuntimeDir -Recurse -Force }
        Move-Item $innerDir.FullName $script:RuntimeDir
        Remove-Item $runtimeZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Java runtime установлен." 85
    } else {
        Write-Log "Java runtime актуален." 85
    }

    if ($NoLauncherStart) {
        Write-Log "Готово (NoLauncherStart)." 100
        return
    }

    # ── 3. Запуск GravitLauncher ─────────────────────────────────────────────
    Write-Log "Запускаем лаунчер..." 95
    Start-Process -FilePath $javaExe -ArgumentList @("-jar", $script:LauncherJar) -WorkingDirectory $script:AppRoot
    Write-Log "Лаунчер запущен. Окно закроется автоматически." 100
    Start-Sleep -Seconds 2
    if ($script:ui) { $script:ui.Form.BeginInvoke([Action]{ $script:ui.Form.Close() }) }
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────
$script:ui = $null

if ($NoLauncherStart) {
    Invoke-Bootstrap
    exit 0
}

$bg = New-Object System.ComponentModel.BackgroundWorker
$bg.WorkerReportsProgress = $true
$bg.Add_DoWork({
    try {
        Invoke-Bootstrap
    } catch {
        $err = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            "Ошибка запуска лаунчера:`n$err",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        if ($script:ui) { $script:ui.Form.Invoke([Action]{ $script:ui.Form.Close() }) }
    }
})

$script:ui = Build-UI
$script:ui.Form.Add_Shown({ $bg.RunWorkerAsync() })
[System.Windows.Forms.Application]::Run($script:ui.Form)