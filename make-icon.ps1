# Convert a source image (png/webp/jpg/...) -> icon.ico for Daily To-Do, then refresh shortcuts.
# Priority: icon.png, else icon.webp, else the most recent image file in this folder.

Add-Type -AssemblyName System.Drawing

$AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$IcoPath = Join-Path $AppDir "icon.ico"

function Find-SourceImage {
    param([string]$dir)
    $preferred = @("icon.png", "icon.webp", "icon.jpg", "icon.jpeg", "icon.bmp")
    foreach ($name in $preferred) {
        $p = Join-Path $dir $name
        if (Test-Path $p) { return $p }
    }
    $exts = @(".png", ".webp", ".jpg", ".jpeg", ".bmp", ".gif")
    $candidate = Get-ChildItem -Path $dir -File |
        Where-Object { $exts -contains $_.Extension.ToLower() -and $_.Name -ne "icon.ico" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Load-Bitmap {
    param([string]$path)
    # Try GDI+ first (fast for png/jpg/bmp).
    try {
        return [System.Drawing.Bitmap]::FromFile($path)
    } catch {
        # Fall back to WIC (Windows Imaging), which handles webp and more.
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        $stream = [System.IO.File]::OpenRead($path)
        try {
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frame = $decoder.Frames[0]
            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($frame))
            $memory = New-Object System.IO.MemoryStream
            $encoder.Save($memory)
            $memory.Position = 0
            return [System.Drawing.Bitmap]::FromStream($memory)
        } finally {
            $stream.Close()
        }
    }
}

$SrcPath = Find-SourceImage $AppDir
if (-not $SrcPath) {
    Write-Host "No source image found in:"
    Write-Host "  $AppDir"
    Write-Host "Drop an image (png/webp/jpg) in this folder and run this again."
    return
}

Write-Host "Using source image:"
Write-Host "  $SrcPath"

# Render the source into PNG blobs at several sizes. Windows uses the small
# entries (16/24/32) for the taskbar/title; without them it often falls back to
# the host process icon (e.g. the PowerShell logo).
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngList = @()
$src = Load-Bitmap $SrcPath
try {
    foreach ($size in $sizes) {
        $canvas = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($canvas)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($src, 0, 0, $size, $size)
        $g.Dispose()

        $ms = New-Object System.IO.MemoryStream
        $canvas.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $canvas.Dispose()
        $pngList += , @{ Size = $size; Bytes = $ms.ToArray() }
        $ms.Dispose()
    }
} finally {
    $src.Dispose()
}

# Write a multi-image ICO that embeds each PNG (Windows Vista+ supports PNG-in-ICO).
$count = $pngList.Count
$fs = New-Object System.IO.FileStream($IcoPath, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    # ICONDIR
    $bw.Write([UInt16]0)        # reserved
    $bw.Write([UInt16]1)        # type = icon
    $bw.Write([UInt16]$count)   # image count

    # ICONDIRENTRY table; data starts after the header + all entries.
    $offset = 6 + (16 * $count)
    foreach ($img in $pngList) {
        $dim = if ($img.Size -ge 256) { 0 } else { [Byte]$img.Size }
        $bw.Write([Byte]$dim)   # width  (0 => 256)
        $bw.Write([Byte]$dim)   # height (0 => 256)
        $bw.Write([Byte]0)      # palette count
        $bw.Write([Byte]0)      # reserved
        $bw.Write([UInt16]1)    # color planes
        $bw.Write([UInt16]32)   # bits per pixel
        $bw.Write([UInt32]$img.Bytes.Length)  # image data size
        $bw.Write([UInt32]$offset)            # image data offset
        $offset += $img.Bytes.Length
    }
    # Image data blobs, in the same order.
    foreach ($img in $pngList) {
        $bw.Write($img.Bytes)
    }
    $bw.Flush()
} finally {
    $bw.Dispose()
    $fs.Dispose()
}

Write-Host "Created icon:"
Write-Host "  $IcoPath"

# Refresh shortcut icons (Startup + Desktop) to use the new icon.ico.
$installScript = Join-Path $AppDir "install_startup.ps1"
if (Test-Path $installScript) {
    Write-Host ""
    Write-Host "Refreshing shortcuts with the new icon..."
    & $installScript
}
