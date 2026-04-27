<#
.SYNOPSIS
    Generates icon.ico for MinecraftTechLauncher using GDI+.
    Creates three sizes: 16, 32, 48 px.  The ICO uses inline PNG data (Vista+ format).
#>

param(
    [string]$OutPath = "$PSScriptRoot\icon.ico"
)

Add-Type -AssemblyName System.Drawing

function New-GearBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # Background – deep navy
    $g.Clear([System.Drawing.Color]::FromArgb(10, 20, 38))

    $cx = $Size / 2.0
    $cy = $Size / 2.0
    $R  = $Size * 0.44   # outer gear radius
    $r  = $Size * 0.26   # inner gear radius
    $rh = $Size * 0.14   # hole radius
    $teeth = 8

    # Build gear polygon points
    $pts = [System.Collections.Generic.List[System.Drawing.PointF]]::new()
    for ($i = 0; $i -lt ($teeth * 2); $i++) {
        $angle  = [Math]::PI * $i / $teeth - [Math]::PI / ($teeth * 2)
        $radius = if ($i % 2 -eq 0) { $R } else { $r }
        $pts.Add([System.Drawing.PointF]::new(
            [float]($cx + $radius * [Math]::Cos($angle)),
            [float]($cy + $radius * [Math]::Sin($angle))
        ))
    }

    # Draw filled gear in cyan
    $cyanBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(14, 165, 233))
    $g.FillPolygon($cyanBrush, $pts.ToArray())
    $cyanBrush.Dispose()

    # Punch inner hole
    $holeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(10, 20, 38))
    $g.FillEllipse($holeBrush, [float]($cx - $rh), [float]($cy - $rh), [float]($rh * 2), [float]($rh * 2))
    $holeBrush.Dispose()

    $g.Dispose()
    return $bmp
}

function New-IcoFile {
    param([System.Drawing.Bitmap[]]$Bitmaps, [string]$OutPath)

    # Each image stored as PNG bytes
    $pngChunks = foreach ($bmp in $Bitmaps) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        ,$ms.ToArray()
        $ms.Dispose()
    }

    $stream = [System.IO.File]::Create($OutPath)
    $w      = New-Object System.IO.BinaryWriter($stream)

    # ICONDIR header
    $w.Write([uint16]0)                          # reserved
    $w.Write([uint16]1)                          # type = icon
    $w.Write([uint16]$Bitmaps.Length)            # image count

    # Calculate offsets: header=6, entries=16 each
    $entryBlock = 6 + 16 * $Bitmaps.Length
    $offsets    = @()
    $cur        = $entryBlock
    for ($i = 0; $i -lt $Bitmaps.Length; $i++) {
        $offsets += $cur
        $cur     += $pngChunks[$i].Length
    }

    # ICONDIRENTRY * N
    for ($i = 0; $i -lt $Bitmaps.Length; $i++) {
        $wPx = if ($Bitmaps[$i].Width  -ge 256) { [byte]0 } else { [byte]$Bitmaps[$i].Width  }
        $hPx = if ($Bitmaps[$i].Height -ge 256) { [byte]0 } else { [byte]$Bitmaps[$i].Height }
        $w.Write($wPx)                           # width
        $w.Write($hPx)                           # height
        $w.Write([byte]0)                        # color count (0 = use PNG)
        $w.Write([byte]0)                        # reserved
        $w.Write([uint16]1)                      # planes
        $w.Write([uint16]32)                     # bit count
        $w.Write([uint32]$pngChunks[$i].Length)  # data size
        $w.Write([uint32]$offsets[$i])           # data offset
    }

    # PNG data
    foreach ($chunk in $pngChunks) {
        $w.Write($chunk)
    }

    $w.Flush()
    $w.Dispose()
    $stream.Dispose()
}

$bitmaps = @(
    (New-GearBitmap -Size 16),
    (New-GearBitmap -Size 32),
    (New-GearBitmap -Size 48)
)

New-IcoFile -Bitmaps $bitmaps -OutPath $OutPath

foreach ($b in $bitmaps) { $b.Dispose() }

Write-Host "Icon generated: $OutPath"
