param(
    [string]$ManifestUrl  = "http://95.105.73.172:8088/manifest.json",
    [string]$ServerStatus = "https://api.mcsrvstat.us/3/95.105.73.172:25565",
    [string]$LauncherVersion = "2.0.0",
    [switch]$NoLauncherStart
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:PortableRoot = Join-Path $env:LOCALAPPDATA "MinecraftTechLauncher"
$script:HMCLBinDir = Join-Path $script:PortableRoot "hmcl"
$script:HMCLExe = Join-Path $script:HMCLBinDir "HMCL.exe"
$script:HMCLDataDir = Join-Path $script:PortableRoot ".hmcl"
$script:HMCLHomeDir = Join-Path $script:PortableRoot ".hmcl-home"
$script:HMCLConfigPath = Join-Path $script:HMCLDataDir "hmcl.json"
$script:HMCLGlobalConfigPath = Join-Path $script:HMCLHomeDir "config.json"
$script:HMCLVersionMarker = Join-Path $script:HMCLBinDir "hmcl-release.txt"
$script:GameRoot = Join-Path $script:PortableRoot "game"

function Get-FileSHA512 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Ensure-Directory {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
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

function Get-DefaultPlayerName {
    $raw = if ($script:ui -and $script:ui.PlayerNameBox.Text) {
        $script:ui.PlayerNameBox.Text
    }
    elseif ($env:USERNAME) {
        $env:USERNAME
    }
    else {
        "Player"
    }

    $safe = ($raw -replace '[^A-Za-z0-9_]', '')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "Player"
    }
    if ($safe.Length -gt 16) {
        $safe = $safe.Substring(0, 16)
    }
    return $safe
}

function Get-OfflinePlayerUuid {
    param([string]$PlayerName)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$PlayerName")
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash($bytes)
    }
    finally {
        $md5.Dispose()
    }

    $hash[6] = ($hash[6] -band 0x0f) -bor 0x30
    $hash[8] = ($hash[8] -band 0x3f) -bor 0x80

    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    return "{0}-{1}-{2}-{3}-{4}" -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Get-TargetVersionId {
    param([pscustomobject]$Manifest)
    return "neoforge-$($Manifest.neoforge.version)"
}

function Get-PackProfileName {
    param([pscustomobject]$Manifest)
    if ($Manifest.pack -and $Manifest.pack.name) {
        return [string]$Manifest.pack.name
    }
    return "Create Aeronautics Pack"
}

function Find-Java21 {
    # Search for a Java 17+ executable, preferring Temurin/Eclipse installations
    $candidates = @()

    # 1. Check JAVA_HOME
    if ($env:JAVA_HOME) {
        $p = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path $p) { $candidates += $p }
    }

    # 2. Well-known Temurin/MSJDK install dirs
    $searchRoots = @(
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\Java",
        "C:\Program Files\Eclipse Adoptium",
        "C:\Program Files\Microsoft"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -notmatch 'javaw' } |
                     Sort-Object FullName -Descending
            foreach ($f in $found) { $candidates += $f.FullName }
        }
    }

    # 3. Registry: Temurin (Eclipse Adoptium) or JDK entries
    $regPaths = @(
        'HKLM:\SOFTWARE\Eclipse Adoptium\JRE',
        'HKLM:\SOFTWARE\Eclipse Adoptium\JDK',
        'HKLM:\SOFTWARE\JavaSoft\JDK'
    )
    foreach ($reg in $regPaths) {
        if (Test-Path $reg) {
            Get-ChildItem $reg -ErrorAction SilentlyContinue | ForEach-Object {
                $javaHome = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).JavaHome
                if ($javaHome) {
                    $p = Join-Path $javaHome 'bin\java.exe'
                    if (Test-Path $p) { $candidates += $p }
                }
            }
        }
    }

    # Try each candidate - return first one that reports version 17+
    # Use --version (Java 9+) which writes to stdout; format: "openjdk 21.0.8 ..."
    foreach ($exe in $candidates) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = '--version'
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $pr = [System.Diagnostics.Process]::Start($psi)
            $out = $pr.StandardOutput.ReadLine()
            $pr.WaitForExit()
            # Matches: "openjdk 21.0.8 ..." or "java 21.0.8 ..."
            if ($out -match '(?:openjdk|java)\s+(\d+)') {
                $major = [int]$Matches[1]
                if ($major -ge 17) { return $exe }
            }
        } catch {}
    }

    return $null
}

function Ensure-Java {
    param(
        [object]$Reporter,
        [pscustomobject]$ProgressState
    )

    $java = Find-Java21
    if ($java) {
        Invoke-ReporterProgress -Reporter $Reporter -Percent $ProgressState.Percent -State ([pscustomobject]@{
            status = "Java найдена"
            log = "Java 17+ найдена: $java"
        })
        return $java
    }

    Invoke-ReporterProgress -Reporter $Reporter -Percent $ProgressState.Percent -State ([pscustomobject]@{
        status = "Установка Java"
        log = "Java 17+ не найдена. Устанавливаем Temurin 21 через winget..."
    })

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget не найден. Установите App Installer из Microsoft Store и запустите снова."
    }

    $installArgs = @(
        "install",
        "--id", "EclipseAdoptium.Temurin.21.JRE",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent"
    )
    $proc = Start-Process -FilePath "winget" -ArgumentList $installArgs -PassThru -Wait
    # -1978335189 (0x8A150013) = already installed / no update available — treat as success
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne -1978335189) {
        throw "Установка Java завершилась с ошибкой: код $($proc.ExitCode)"
    }

    # Re-discover after install (PATH may not update in current process)
    $java = Find-Java21
    if (-not $java) {
        # Fallback: glob for newly installed Temurin
        $java = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $java) {
        throw "Java установлена, но исполняемый файл не найден. Перезапустите лаунчер."
    }
    return $java
}

function Ensure-NeoForge {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$Percent
    )

    $versionsDir = Join-Path $script:GameRoot "versions"
    $targetVersion = Get-TargetVersionId -Manifest $Manifest
    $targetDir = Join-Path $versionsDir $targetVersion

    if (Test-Path $targetDir) {
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "NeoForge готов"
            log = "NeoForge уже установлен: $targetVersion"
        })
        return $targetVersion
    }

    Ensure-Directory -Path $script:GameRoot
    Ensure-Directory -Path $versionsDir

    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    Ensure-Directory -Path $tmpDir

    $installerPath = Join-Path $tmpDir "neoforge-installer.jar"
    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Загрузка NeoForge"
        log = "Скачиваем установщик NeoForge: $($Manifest.neoforge.version)"
    })
    Invoke-WebRequest -Uri $Manifest.neoforge.installer_url -OutFile $installerPath

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Установка NeoForge"
        log = "Устанавливаем NeoForge в портативную директорию"
    })

    # Use the same Java 17+ that was selected for this session (stored in script-scope)
    $javaExe = if ($script:JavaExe -and (Test-Path $script:JavaExe)) { $script:JavaExe } else { 'java' }
    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Установка NeoForge"
        log = "Используем Java: $javaExe"
    })

    # NeoForge installer requires launcher_profiles.json to exist in the target directory
    $profilesPath = Join-Path $script:GameRoot "launcher_profiles.json"
    if (-not (Test-Path $profilesPath)) {
        $stubProfiles = '{"profiles":{},"settings":{"enableAdvanced":false},"version":3}'
        [System.IO.File]::WriteAllText($profilesPath, $stubProfiles, [System.Text.UTF8Encoding]::new($false))
    }

    $arguments = @("-jar", $installerPath, "--install-client", $script:GameRoot)
    $proc = Start-Process -FilePath $javaExe -ArgumentList $arguments -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Установщик NeoForge завершился с ошибкой: код $($proc.ExitCode). Убедитесь, что установлена Java 17+ (Temurin 21)."
    }

    if (-not (Test-Path $targetDir)) {
        throw "NeoForge установлен, но директория версии не найдена: $targetDir"
    }

    return $targetVersion
}

function Sync-Mods {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$StartPercent,
        [int]$EndPercent
    )

    $modsDir = Join-Path $script:GameRoot "mods"
    Ensure-Directory -Path $modsDir

    $expected = @{}
    foreach ($mod in $Manifest.mods) {
        $expected[$mod.filename] = $mod
    }

    Invoke-ReporterProgress -Reporter $Reporter -Percent $StartPercent -State ([pscustomobject]@{
        status = "Preparing mods"
        log = "Removing stale mods from portable pack"
    })

    Get-ChildItem $modsDir -Filter "*.jar" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $expected.ContainsKey($_.Name)) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $total = [Math]::Max(1, $Manifest.mods.Count)
    $index = 0

    foreach ($mod in $Manifest.mods) {
        $index++
        $segment = [double]($EndPercent - $StartPercent)
        $pct = [int]($StartPercent + (($index / $total) * $segment))
        $target = Join-Path $modsDir $mod.filename
        $needDownload = $true

        if (Test-Path $target) {
            $hash = Get-FileSHA512 -Path $target
            if ($hash -eq $mod.sha512) {
                $needDownload = $false
            }
        }

        if ($needDownload) {
            Invoke-ReporterProgress -Reporter $Reporter -Percent $pct -State ([pscustomobject]@{
                status = "Синхронизация модов ($index/$total)"
                log = "Скачиваем $($mod.filename)"
            })
            Invoke-WebRequest -Uri $mod.url -OutFile $target
            $hash = Get-FileSHA512 -Path $target
            if ($hash -ne $mod.sha512) {
                throw "Контрольная сумма не совпадает после загрузки: $($mod.filename)"
            }
        }
        else {
            Invoke-ReporterProgress -Reporter $Reporter -Percent $pct -State ([pscustomobject]@{
                status = "Синхронизация модов ($index/$total)"
                log = "Актуально: $($mod.filename)"
            })
        }
    }
}

function Get-HMCLDownloadInfo {
    param([pscustomobject]$Manifest)

    $defaultUrl = "https://github.com/HMCL-dev/HMCL/releases/download/release-3.12.4/HMCL-3.12.4.exe"
    $defaultVersion = "3.12.4"

    return [pscustomobject]@{
        Url = if ($Manifest.launcher -and $Manifest.launcher.hmcl_download_url) { [string]$Manifest.launcher.hmcl_download_url } else { $defaultUrl }
        Version = if ($Manifest.launcher -and $Manifest.launcher.hmcl_version) { [string]$Manifest.launcher.hmcl_version } else { $defaultVersion }
    }
}

function Ensure-HMCL {
    param(
        [pscustomobject]$Manifest,
        [object]$Reporter,
        [int]$Percent
    )

    Ensure-Directory -Path $script:PortableRoot
    Ensure-Directory -Path $script:HMCLBinDir
    Ensure-Directory -Path $script:HMCLDataDir
    Ensure-Directory -Path $script:HMCLHomeDir

    $downloadInfo = Get-HMCLDownloadInfo -Manifest $Manifest
    $installedVersion = if (Test-Path $script:HMCLVersionMarker) {
        (Get-Content $script:HMCLVersionMarker -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    else {
        $null
    }

    if ((Test-Path $script:HMCLExe) -and $installedVersion -eq $downloadInfo.Version) {
        Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
            status = "HMCL готов"
            log = "HMCL уже установлен: $installedVersion"
        })
        return $script:HMCLExe
    }

    $tmpDir = Join-Path $env:TEMP "mc-autoclient"
    Ensure-Directory -Path $tmpDir
    $downloadPath = Join-Path $tmpDir "HMCL.exe"

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "Загрузка HMCL"
            log = "Скачиваем HMCL портативный $($downloadInfo.Version)"
    })
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $downloadPath

    Copy-Item -Path $downloadPath -Destination $script:HMCLExe -Force
    Set-Content -Path $script:HMCLVersionMarker -Value $downloadInfo.Version -Encoding UTF8

    Invoke-ReporterProgress -Reporter $Reporter -Percent $Percent -State ([pscustomobject]@{
        status = "HMCL готов"
            log = "HMCL обновлён до $($downloadInfo.Version)"
    })

    return $script:HMCLExe
}

function Write-HMCLConfig {
    param(
        [pscustomobject]$Manifest,
        [string]$VersionId,
        [int]$RamMb,
        [string]$PlayerName
    )

    Ensure-Directory -Path $script:HMCLDataDir
    Ensure-Directory -Path $script:HMCLHomeDir
    Ensure-Directory -Path $script:GameRoot

    $profileName = Get-PackProfileName -Manifest $Manifest
    $playerUuid = Get-OfflinePlayerUuid -PlayerName $PlayerName
    $serverAddress = if ($Manifest.pack -and $Manifest.pack.server_address) { [string]$Manifest.pack.server_address } else { "95.105.73.172:25565" }

    $globalConfig = [ordered]@{
        agreementVersion = 0
        terracottaAgreementVersion = 0
        platformPromptVersion = 0
        logRetention = 20
        enableOfflineAccount = $true
        userJava = @()
        disabledJava = @()
    }

    $config = [ordered]@{
        _version = 2
        uiVersion = 0
        commonDirType = 1
        commonpath = $script:GameRoot
        preferredLoginType = "offline"
        selectedAccount = "${PlayerName}:${PlayerName}"
        accounts = @(
            [ordered]@{
                type = "offline"
                username = $PlayerName
                uuid = $playerUuid
                skin = [ordered]@{
                    type = "default"
                    cslApi = $null
                    textureModel = "default"
                    localSkinPath = $null
                    localCapePath = $null
                }
            }
        )
        last = $profileName
        configurations = [ordered]@{}
    }

    $config.configurations[$profileName] = [ordered]@{
        global = [ordered]@{
            usesGlobal = $true
            maxMemory = $RamMb
            autoMemory = $false
            serverIp = $serverAddress
            width = 1280
            height = 720
            java = "Auto"
            javaVersionType = "AUTO"
            gameDirType = 0
            launcherVisibility = 0
            showLogs = $false
        }
        gameDir = $script:GameRoot
        useRelativePath = $false
        selectedMinecraftVersion = $VersionId
    }

    $globalConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:HMCLGlobalConfigPath -Encoding UTF8
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $script:HMCLConfigPath -Encoding UTF8
}

function Start-HMCL {
    param([string]$ExecutablePath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExecutablePath
    $psi.WorkingDirectory = Split-Path $ExecutablePath -Parent
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['HMCL_LOCAL_HOME'] = $script:HMCLDataDir
    $psi.EnvironmentVariables['HMCL_USER_HOME'] = $script:HMCLHomeDir

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) {
        throw "Не удалось запустить HMCL."
    }
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

$C = @{
    Bg         = [System.Drawing.Color]::FromArgb(10, 14, 22)
    HeaderTop  = [System.Drawing.Color]::FromArgb(8, 18, 35)
    HeaderBot  = [System.Drawing.Color]::FromArgb(14, 30, 55)
    Accent     = [System.Drawing.Color]::FromArgb(14, 165, 233)
    AccentDark = [System.Drawing.Color]::FromArgb(7, 89, 133)
    TextPrim   = [System.Drawing.Color]::FromArgb(226, 232, 240)
    TextMuted  = [System.Drawing.Color]::FromArgb(100, 116, 139)
    TextGreen  = [System.Drawing.Color]::FromArgb(74, 222, 128)
    TextRed    = [System.Drawing.Color]::FromArgb(248, 113, 113)
    Panel      = [System.Drawing.Color]::FromArgb(15, 23, 42)
    LogBg      = [System.Drawing.Color]::FromArgb(7, 12, 20)
    BtnSub     = [System.Drawing.Color]::FromArgb(30, 41, 59)
}

function New-BannerBitmap {
    $width = 860
    $height = 110
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $backgroundBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Rectangle(0, 0, $width, $height)),
        [System.Drawing.Color]::FromArgb(8, 18, 38),
        [System.Drawing.Color]::FromArgb(16, 32, 62),
        [System.Drawing.Drawing2D.LinearGradientMode]::BackwardDiagonal)
    $graphics.FillRectangle($backgroundBrush, 0, 0, $width, $height)
    $backgroundBrush.Dispose()

    $stripePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(12, 100, 180, 255))
    for ($x = -$height; $x -lt $width; $x += 36) {
        $graphics.DrawLine($stripePen, $x, 0, $x + $height, $height)
    }
    $stripePen.Dispose()

    $accentPen = New-Object System.Drawing.Pen($C.Accent)
    $accentPen.Width = 2.0
    $graphics.DrawLine($accentPen, 0, $height - 2, $width, $height - 2)
    $accentPen.Dispose()

    $barBrush = New-Object System.Drawing.SolidBrush($C.Accent)
    $graphics.FillRectangle($barBrush, 0, 0, 4, $height)
    $barBrush.Dispose()

    $titleFont = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 248, 255))
    $graphics.DrawString("Create Aeronautics  -  HMCL Портативный клиент", $titleFont, $titleBrush, 18, 12)
    $titleFont.Dispose()
    $titleBrush.Dispose()

    $subtitleFont = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(148, 163, 184))
    $graphics.DrawString("Отдельная директория пака, оффлайн-аккаунт, NeoForge 1.21.1, синхронизация модов, HMCL", $subtitleFont, $subtitleBrush, 18, 54)
    $subtitleFont.Dispose()
    $subtitleBrush.Dispose()

    $versionFont = New-Object System.Drawing.Font("Segoe UI", 8)
    $versionBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(71, 85, 105))
    $versionText = "Launcher v$LauncherVersion"
    $size = $graphics.MeasureString($versionText, $versionFont)
    $graphics.DrawString($versionText, $versionFont, $versionBrush, ($width - $size.Width - 10), ($height - $size.Height - 6))
    $versionFont.Dispose()
    $versionBrush.Dispose()

    $graphics.Dispose()
    return $bitmap
}

function New-LauncherUi {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Minecraft Tech Launcher  v$LauncherVersion  [RU]"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(880, 660)
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = $C.Bg

    $banner = New-Object System.Windows.Forms.PictureBox
    $banner.Location = New-Object System.Drawing.Point(0, 0)
    $banner.Size = New-Object System.Drawing.Size(880, 110)
    $banner.SizeMode = "StretchImage"
    $banner.Image = New-BannerBitmap
    $form.Controls.Add($banner)

    $srvPanel = New-Object System.Windows.Forms.Panel
    $srvPanel.Location = New-Object System.Drawing.Point(0, 110)
    $srvPanel.Size = New-Object System.Drawing.Size(880, 36)
    $srvPanel.BackColor = $C.Panel

    $srvDot = New-Object System.Windows.Forms.Panel
    $srvDot.BackColor = $C.TextMuted
    $srvDot.Location = New-Object System.Drawing.Point(16, 12)
    $srvDot.Size = New-Object System.Drawing.Size(10, 10)

    $srvLabel = New-Object System.Windows.Forms.Label
    $srvLabel.Text = "Сервер: проверка..."
    $srvLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $srvLabel.ForeColor = $C.TextMuted
    $srvLabel.Location = New-Object System.Drawing.Point(34, 9)
    $srvLabel.Size = New-Object System.Drawing.Size(400, 18)

    $srvRefreshBtn = New-Object System.Windows.Forms.Button
    $srvRefreshBtn.Text = "Обновить"
    $srvRefreshBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $srvRefreshBtn.FlatStyle = "Flat"
    $srvRefreshBtn.FlatAppearance.BorderSize = 0
    $srvRefreshBtn.BackColor = $C.Panel
    $srvRefreshBtn.ForeColor = $C.TextMuted
    $srvRefreshBtn.Location = New-Object System.Drawing.Point(450, 4)
    $srvRefreshBtn.Size = New-Object System.Drawing.Size(78, 28)

    $srvPanel.Controls.AddRange(@($srvDot, $srvLabel, $srvRefreshBtn))
    $form.Controls.Add($srvPanel)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Готово"
    $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9.5)
    $statusLabel.ForeColor = $C.Accent
    $statusLabel.Location = New-Object System.Drawing.Point(14, 155)
    $statusLabel.Size = New-Object System.Drawing.Size(760, 20)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(14, 178)
    $progress.Size = New-Object System.Drawing.Size(848, 20)
    $progress.Minimum = 0
    $progress.Maximum = 100

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ScrollBars = "Vertical"
    $log.ReadOnly = $true
    $log.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $log.BackColor = $C.LogBg
    $log.ForeColor = $C.TextPrim
    $log.BorderStyle = "FixedSingle"
    $log.Location = New-Object System.Drawing.Point(14, 206)
    $log.Size = New-Object System.Drawing.Size(848, 360)

    $playerLabel = New-Object System.Windows.Forms.Label
    $playerLabel.Text = "Ник:"
    $playerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $playerLabel.ForeColor = $C.TextMuted
    $playerLabel.Location = New-Object System.Drawing.Point(14, 580)
    $playerLabel.Size = New-Object System.Drawing.Size(40, 24)

    $playerBox = New-Object System.Windows.Forms.TextBox
    $playerBox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $playerBox.BackColor = $C.BtnSub
    $playerBox.ForeColor = $C.TextPrim
    $playerBox.BorderStyle = "FixedSingle"
    $playerBox.Location = New-Object System.Drawing.Point(58, 576)
    $playerBox.Size = New-Object System.Drawing.Size(140, 26)
    $playerBox.Text = Get-DefaultPlayerName

    $ramLabel = New-Object System.Windows.Forms.Label
    $ramLabel.Text = "ОЗУ:"
    $ramLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $ramLabel.ForeColor = $C.TextMuted
    $ramLabel.Location = New-Object System.Drawing.Point(214, 580)
    $ramLabel.Size = New-Object System.Drawing.Size(36, 24)

    $ramCombo = New-Object System.Windows.Forms.ComboBox
    $ramCombo.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $ramCombo.FlatStyle = "Flat"
    $ramCombo.BackColor = $C.BtnSub
    $ramCombo.ForeColor = $C.TextPrim
    $ramCombo.DropDownStyle = "DropDownList"
    $ramCombo.Location = New-Object System.Drawing.Point(252, 576)
    $ramCombo.Size = New-Object System.Drawing.Size(90, 26)
    @("2 GB","3 GB","4 GB","6 GB","8 GB","12 GB","16 GB") | ForEach-Object { [void]$ramCombo.Items.Add($_) }
    $ramCombo.SelectedIndex = 2

    $playBtn = New-Object System.Windows.Forms.Button
    $playBtn.Text = "Подготовить и запустить HMCL"
    $playBtn.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $playBtn.BackColor = $C.AccentDark
    $playBtn.ForeColor = [System.Drawing.Color]::White
    $playBtn.FlatStyle = "Flat"
    $playBtn.FlatAppearance.BorderColor = $C.Accent
    $playBtn.Location = New-Object System.Drawing.Point(360, 574)
    $playBtn.Size = New-Object System.Drawing.Size(190, 36)

    $updateBtn = New-Object System.Windows.Forms.Button
    $updateBtn.Text = "Обновить паки"
    $updateBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $updateBtn.BackColor = $C.BtnSub
    $updateBtn.ForeColor = $C.TextPrim
    $updateBtn.FlatStyle = "Flat"
    $updateBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $updateBtn.Location = New-Object System.Drawing.Point(562, 574)
    $updateBtn.Size = New-Object System.Drawing.Size(140, 36)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Закрыть"
    $closeBtn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $closeBtn.BackColor = $C.Bg
    $closeBtn.ForeColor = $C.TextMuted
    $closeBtn.FlatStyle = "Flat"
    $closeBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $closeBtn.Location = New-Object System.Drawing.Point(754, 574)
    $closeBtn.Size = New-Object System.Drawing.Size(108, 36)
    $closeBtn.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@($statusLabel, $progress, $log, $playerLabel, $playerBox, $ramLabel, $ramCombo, $playBtn, $updateBtn, $closeBtn))

    return [pscustomobject]@{
        Form          = $form
        SrvDot        = $srvDot
        SrvLabel      = $srvLabel
        SrvRefresh    = $srvRefreshBtn
        Status        = $statusLabel
        Progress      = $progress
        Log           = $log
        PlayerNameBox = $playerBox
        RamCombo      = $ramCombo
        PlayButton    = $playBtn
        UpdateButton  = $updateBtn
    }
}

function Add-LogLine {
    param([System.Windows.Forms.TextBox]$Log, [string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $Log.AppendText($line + [Environment]::NewLine)
    $Log.SelectionStart = $Log.Text.Length
    $Log.ScrollToCaret()
}

function Update-ServerStatus {
    $dot = $script:ui.SrvDot
    $label = $script:ui.SrvLabel

    try {
        $response = Invoke-RestMethod -Uri $script:ServerStatus -TimeoutSec 6 -ErrorAction Stop
    }
    catch {
        $response = $null
    }

    if ($response -and $response.online) {
        $players = "$($response.players.online)/$($response.players.max)"
        $dot.BackColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $label.Text = "95.105.73.172  -  Онлайн  -  игроков: $players"
    }
    else {
        $dot.BackColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $label.Text = "95.105.73.172  -  Офлайн"
    }
}

function Get-RamMb {
    param([string]$Selected)
    $map = @{
        "2 GB" = 2048
        "3 GB" = 3072
        "4 GB" = 4096
        "6 GB" = 6144
        "8 GB" = 8192
        "12 GB" = 12288
        "16 GB" = 16384
    }
    if ($map.ContainsKey($Selected)) {
        return $map[$Selected]
    }
    return 4096
}

$ui = New-LauncherUi

$srvTimer = New-Object System.Windows.Forms.Timer
$srvTimer.Interval = 60000
$srvTimer.Add_Tick({ Update-ServerStatus })
$ui.SrvRefresh.Add_Click({ Update-ServerStatus })

function Invoke-ClientFlow {
    param([bool]$UpdateOnly)

    $reporter = New-UiReporter
    $manifest = $null

    try {
        $playerName = Get-DefaultPlayerName
        $script:ui.PlayerNameBox.Text = $playerName
        $ramMb = Get-RamMb -Selected $script:ui.RamCombo.SelectedItem

        & $reporter.ReportProgress 5 ([pscustomobject]@{ status = "Загрузка манифеста"; log = "Загружаем манифест с $script:ManifestUrl" })
        $manifest = Invoke-RestMethod -Uri $script:ManifestUrl

        & $reporter.ReportProgress 12 ([pscustomobject]@{ status = "Подготовка директории"; log = "Портативная директория: $script:PortableRoot" })
        Ensure-Directory -Path $script:PortableRoot
        Ensure-Directory -Path $script:GameRoot

        & $reporter.ReportProgress 18 ([pscustomobject]@{ status = "Проверка Java"; log = "Проверяем Java Runtime" })
        $script:JavaExe = Ensure-Java -Reporter $reporter -ProgressState ([pscustomobject]@{ Percent = 22 })

        & $reporter.ReportProgress 30 ([pscustomobject]@{ status = "Проверка NeoForge"; log = "Проверяем портативный экземпляр NeoForge" })
        $versionId = Ensure-NeoForge -Manifest $manifest -Reporter $reporter -Percent 38

        & $reporter.ReportProgress 45 ([pscustomobject]@{ status = "Синхронизация модов"; log = "Сравниваем моды с манифестом сервера" })
        Sync-Mods -Manifest $manifest -Reporter $reporter -StartPercent 45 -EndPercent 82

        & $reporter.ReportProgress 86 ([pscustomobject]@{ status = "Инициализация HMCL"; log = "Подготавливаем портативный HMCL" })
        $hmclExe = Ensure-HMCL -Manifest $manifest -Reporter $reporter -Percent 90

        & $reporter.ReportProgress 94 ([pscustomobject]@{ status = "Запись конфига HMCL"; log = "Сохраняем профиль, аккаунт и настройки памяти" })
        Write-HMCLConfig -Manifest $manifest -VersionId $versionId -RamMb $ramMb -PlayerName $playerName

        if (-not $UpdateOnly -and -not $script:NoLauncherStart) {
            & $reporter.ReportProgress 98 ([pscustomobject]@{ status = "Запуск HMCL"; log = "Открываем HMCL с подготовленным профилем ($playerName, ${ramMb}МБ)" })
            Start-HMCL -ExecutablePath $hmclExe
            & $reporter.ReportProgress 100 ([pscustomobject]@{ status = "HMCL запущен"; log = "HMCL открыт. Профиль пака выбран и готов к игре." })
        }
        else {
            & $reporter.ReportProgress 100 ([pscustomobject]@{ status = "Пак обновлён"; log = "Портативный пак HMCL актуален." })
        }

        $server = if ($manifest -and $manifest.pack) { $manifest.pack.server_address } else { "unknown" }
        $script:ui.Status.Text = "Готово  -  Сервер: $server"
        $script:ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        Add-LogLine -Log $script:ui.Log -Message ("Готово. Директория пака: $script:PortableRoot")
    }
    catch {
        $message = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        $script:ui.Status.Text = "Ошибка"
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

    $script:ui.PlayButton.Enabled = $false
    $script:ui.UpdateButton.Enabled = $false
    $script:ui.Status.ForeColor = [System.Drawing.Color]::FromArgb(14, 165, 233)
    $script:ui.Progress.Value = 0
    Add-LogLine -Log $script:ui.Log -Message "--- $(if ($UpdateOnly) { 'Обновление пака' } else { 'Инициализация HMCL' }) ---"
    Invoke-ClientFlow -UpdateOnly:$UpdateOnly
}

$ui.PlayButton.Add_Click({ Start-ClientFlow -UpdateOnly:$false })
$ui.UpdateButton.Add_Click({ Start-ClientFlow -UpdateOnly:$true })

$ui.Form.Add_Shown({
    $srvTimer.Start()
    Update-ServerStatus
    $script:ui.PlayerNameBox.Text = Get-DefaultPlayerName
    $script:ui.Status.Text = "Готово"
    Add-LogLine -Log $script:ui.Log -Message "Лаунчер готов. Используется портативный HMCL, отдельная директория, оффлайн-аккаунт."
})

[void]$ui.Form.ShowDialog()
$srvTimer.Stop()
