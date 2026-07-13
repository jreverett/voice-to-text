#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads ffmpeg, whisper.cpp, and the tiny.en model for voice-to-text.
.DESCRIPTION
    Idempotent — skips components that already exist.
    Run from the voice-to-text project root directory.
#>

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# --- Directory Setup ---
$dirs = @("bin", "models", "temp", "icons")
foreach ($dir in $dirs) {
    $path = Join-Path $scriptDir $dir
    if (!(Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        Write-Host "Created $dir\"
    }
}

# --- Download Helper ---
function Download-File {
    param([string]$Url, [string]$OutFile)
    Write-Host "Downloading $(Split-Path $OutFile -Leaf)..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    $ProgressPreference = 'Continue'
}

# --- 1. ffmpeg ---
$ffmpegExe = Join-Path $scriptDir "bin\ffmpeg.exe"
if (!(Test-Path $ffmpegExe)) {
    Write-Host "`n--- Installing ffmpeg ---"
    $ffmpegZip = Join-Path $scriptDir "temp\ffmpeg.zip"
    Download-File -Url "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $ffmpegZip

    Write-Host "Extracting ffmpeg.exe..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ffmpegZip)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like "*/bin/ffmpeg.exe" } | Select-Object -First 1
        if ($entry) {
            $stream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::Create($ffmpegExe)
                try { $stream.CopyTo($fileStream) }
                finally { $fileStream.Close() }
            } finally { $stream.Close() }
            Write-Host "Extracted ffmpeg.exe to bin\"
        } else {
            throw "ffmpeg.exe not found in archive"
        }
    } finally { $zip.Dispose() }

    Remove-Item $ffmpegZip -Force
} else {
    Write-Host "ffmpeg.exe already present, skipping."
}

# --- 2. whisper.cpp ---
$whisperExe = Join-Path $scriptDir "bin\whisper-cli.exe"
if (!(Test-Path $whisperExe)) {
    Write-Host "`n--- Installing whisper.cpp ---"

    # Get latest release info
    Write-Host "Querying latest whisper.cpp release..."
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest" -UseBasicParsing

    # Prefer OpenBLAS build for faster CPU matrix ops, fall back to plain
    $asset = $releaseInfo.assets | Where-Object {
        $_.name -match "whisper-blas-bin-x64\.zip$"
    } | Select-Object -First 1

    if (!$asset) {
        $asset = $releaseInfo.assets | Where-Object {
            $_.name -match "whisper.*bin.*x64\.zip$" -and $_.name -notmatch "cublas|cuda|openblas|arm"
        } | Select-Object -First 1
    }

    if (!$asset) {
        Write-Warning "Could not find whisper.cpp Windows x64 binary in latest release."
        Write-Warning "Available assets:"
        $releaseInfo.assets | ForEach-Object { Write-Warning "  $($_.name)" }
        Write-Warning "Please download manually and place whisper-cli.exe in bin\"
    } else {
        $whisperZip = Join-Path $scriptDir "temp\whisper.zip"
        Download-File -Url $asset.browser_download_url -OutFile $whisperZip

        Write-Host "Extracting whisper binaries..."
        $extractDir = Join-Path $scriptDir "temp\whisper-extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $whisperZip -DestinationPath $extractDir

        # Copy whisper-cli.exe and any DLLs to bin\
        $files = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object {
            $_.Name -eq "whisper-cli.exe" -or
            $_.Name -eq "whisper-server.exe" -or
            $_.Name -eq "main.exe" -or
            $_.Extension -eq ".dll"
        }

        foreach ($file in $files) {
            $destName = if ($file.Name -eq "main.exe") { "whisper-cli.exe" } else { $file.Name }
            $dest = Join-Path $scriptDir "bin\$destName"
            Copy-Item -Path $file.FullName -Destination $dest -Force
            Write-Host "  Copied $destName to bin\"
        }

        Remove-Item $whisperZip -Force
        Remove-Item $extractDir -Recurse -Force
    }
} else {
    Write-Host "whisper-cli.exe already present, skipping."
}

# --- 2b. whisper-server (re-download if missing) ---
$whisperServer = Join-Path $scriptDir "bin\whisper-server.exe"
if (!(Test-Path $whisperServer)) {
    Write-Host "`n--- Downloading whisper-server.exe ---"
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest" -UseBasicParsing
    $asset = $releaseInfo.assets | Where-Object {
        $_.name -match "whisper-blas-bin-x64\.zip$"
    } | Select-Object -First 1
    if (!$asset) {
        $asset = $releaseInfo.assets | Where-Object {
            $_.name -match "whisper.*bin.*x64\.zip$" -and $_.name -notmatch "cublas|cuda|openblas|arm"
        } | Select-Object -First 1
    }
    if ($asset) {
        $whisperZip = Join-Path $scriptDir "temp\whisper.zip"
        Download-File -Url $asset.browser_download_url -OutFile $whisperZip
        $extractDir = Join-Path $scriptDir "temp\whisper-extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $whisperZip -DestinationPath $extractDir
        $serverFile = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object { $_.Name -eq "whisper-server.exe" } | Select-Object -First 1
        if ($serverFile) {
            Copy-Item -Path $serverFile.FullName -Destination $whisperServer -Force
            Write-Host "  Copied whisper-server.exe to bin\"
        } else {
            Write-Warning "whisper-server.exe not found in release archive"
        }
        Remove-Item $whisperZip -Force
        Remove-Item $extractDir -Recurse -Force
    }
} else {
    Write-Host "whisper-server.exe already present, skipping."
}

# --- 3. Model ---
$modelFile = Join-Path $scriptDir "models\ggml-small.en.bin"
if (!(Test-Path $modelFile)) {
    Write-Host "`n--- Downloading ggml-small.en model (~466MB) ---"
    Download-File `
        -Url "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin" `
        -OutFile $modelFile
    Write-Host "Model saved to models\"
} else {
    Write-Host "ggml-small.en.bin already present, skipping."
}

# --- 4. Audio Configuration ---
$configFile = Join-Path $scriptDir "config.ini"
Write-Host "`n--- Using the Windows default input device ---"

# --- 5. Generate Icons ---
$iconsDir = Join-Path $scriptDir "icons"
$iconColors = @{
    "idle"         = @(34, 197, 94)      # Green
    "starting"     = @(251, 146, 60)     # Orange
    "recording"    = @(239, 68, 68)      # Red
    "transcribing" = @(250, 204, 21)     # Yellow
}

$needIcons = $false
foreach ($name in $iconColors.Keys) {
    if (!(Test-Path (Join-Path $iconsDir "$name.ico"))) {
        $needIcons = $true
        break
    }
}

if ($needIcons) {
    Write-Host "`n--- Generating tray icons ---"
    try {
        Add-Type -AssemblyName System.Drawing

        foreach ($name in $iconColors.Keys) {
            $icoPath = Join-Path $iconsDir "$name.ico"
            if (Test-Path $icoPath) { continue }

            $rgb = $iconColors[$name]

            # Create 32x32 ARGB bitmap with filled circle
            $bmp = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear([System.Drawing.Color]::Transparent)

            $color = [System.Drawing.Color]::FromArgb(255, $rgb[0], $rgb[1], $rgb[2])
            $brush = New-Object System.Drawing.SolidBrush($color)
            $g.FillEllipse($brush, 2, 2, 28, 28)

            $darker = [System.Drawing.Color]::FromArgb(255, [Math]::Max(0, $rgb[0]-40), [Math]::Max(0, $rgb[1]-40), [Math]::Max(0, $rgb[2]-40))
            $pen = New-Object System.Drawing.Pen($darker, 1.5)
            $g.DrawEllipse($pen, 2, 2, 28, 28)

            $g.Dispose()
            $brush.Dispose()
            $pen.Dispose()

            # Save as proper .ico by writing the binary format directly
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngBytes = $ms.ToArray()
            $ms.Dispose()
            $bmp.Dispose()

            # ICO file format: header + directory entry + PNG data
            $fs = [System.IO.File]::Create($icoPath)
            $bw = New-Object System.IO.BinaryWriter($fs)

            # ICO header: reserved(2) + type=1(2) + count=1(2)
            $bw.Write([UInt16]0)    # Reserved
            $bw.Write([UInt16]1)    # Type: 1 = ICO
            $bw.Write([UInt16]1)    # Image count

            # Directory entry: width, height, colors, reserved, planes, bpp, size, offset
            $bw.Write([byte]32)     # Width
            $bw.Write([byte]32)     # Height
            $bw.Write([byte]0)      # Color palette (0 = no palette)
            $bw.Write([byte]0)      # Reserved
            $bw.Write([UInt16]1)    # Color planes
            $bw.Write([UInt16]32)   # Bits per pixel
            $bw.Write([UInt32]$pngBytes.Length)  # Image data size
            $bw.Write([UInt32]22)   # Offset to image data (6 header + 16 directory)

            # PNG image data
            $bw.Write($pngBytes)

            $bw.Close()
            $fs.Close()

            Write-Host "  Created $name.ico"
        }
    } catch {
        Write-Warning "Could not generate icons: $_"
        Write-Warning "The script will work without custom icons (uses default AHK icon)."
    }
} else {
    Write-Host "Icons already present, skipping."
}

# --- 6. Startup Shortcut ---
$runAtLogin = (Get-Content $configFile | Select-String 'RunAtLogin=').ToString().Split('=')[1].Trim()
$startupDir = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
$shortcutPath = Join-Path $startupDir "Voice-to-Text.lnk"
$ahkScript = Join-Path $scriptDir "voice-to-text.ahk"

if ($runAtLogin -eq "true") {
    if (!(Test-Path $shortcutPath)) {
        Write-Host "`n--- Creating startup shortcut ---"
        $wshell = New-Object -ComObject WScript.Shell
        $shortcut = $wshell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $ahkScript
        $shortcut.WorkingDirectory = $scriptDir
        $shortcut.Description = "Voice-to-Text push-to-talk"
        $shortcut.Save()
        Write-Host "Startup shortcut created at: $shortcutPath"
    } else {
        Write-Host "Startup shortcut already exists, skipping."
    }
} else {
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "Startup shortcut removed (RunAtLogin=false)."
    }
}

# --- Done ---
Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Double-click voice-to-text.ahk to start"
Write-Host "  2. Hold $((Get-Content $configFile | Select-String 'PushToTalk=').ToString().Split('=')[1]) and speak, release to transcribe"
