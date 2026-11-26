<#
.SYNOPSIS
    Generates the SQLMap icon: assets\SQLMap.ico (16-256 px), assets\SQLMap.png (256 px) and assets\SQLMap.svg.
.DESCRIPTION
    A database cylinder with a magnifying glass on a blue rounded square. Drawn with GDI+ at every size
    (not downscaled) so small sizes stay sharp; small sizes drop the cylinder bands.
    ICO entries up to 128 px are 32-bit DIBs (most compatible); 256 px is PNG-compressed.
#>
[CmdletBinding()]
param([string]$OutFolder = (Join-Path $PSScriptRoot '..\assets'))

Add-Type -AssemblyName System.Drawing
$OutFolder = [System.IO.Path]::GetFullPath($OutFolder)
if (-not (Test-Path $OutFolder)) { $null = New-Item -Path $OutFolder -ItemType Directory -Force }

$blue     = [System.Drawing.Color]::FromArgb(255, 0x2a, 0x78, 0xd6)
$blueDark = [System.Drawing.Color]::FromArgb(255, 0x1c, 0x5c, 0xab)
$white    = [System.Drawing.Color]::FromArgb(255, 0xff, 0xff, 0xff)

function New-RoundedRectPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $p
}

function New-IconBitmap([int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $Size / 256.0                           # design grid is 256 x 256
    $g.ScaleTransform($s, $s)

    # Background
    $bg = New-RoundedRectPath 8 8 240 240 52
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF(0, 256)), $blue, $blueDark)
    $g.FillPath($brush, $bg)

    # Database cylinder
    $wb = New-Object System.Drawing.SolidBrush($white)
    $g.FillRectangle($wb, 46, 66, 124, 112)
    $g.FillEllipse($wb, 46, 46, 124, 40)          # top
    $g.FillEllipse($wb, 46, 158, 124, 40)         # bottom
    $band = New-Object System.Drawing.Pen($blue, 9)
    $g.DrawEllipse($band, 50.5, 50.5, 115, 31)    # rim of the top
    if ($Size -ge 32) {
        $g.DrawArc($band, 46, 94, 124, 40, 0, 180)
        $g.DrawArc($band, 46, 126, 124, 40, 0, 180)
    }

    # Magnifying glass over the bottom-right
    $lensBrush = New-Object System.Drawing.SolidBrush($blueDark)
    $g.FillEllipse($lensBrush, 130, 130, 84, 84)
    $ring = New-Object System.Drawing.Pen($white, 18)
    $g.DrawEllipse($ring, 139, 139, 66, 66)
    $handle = New-Object System.Drawing.Pen($white, 24)
    $handle.StartCap = 'Round'; $handle.EndCap = 'Round'
    $g.DrawLine($handle, 200, 200, 228, 228)

    foreach ($o in $handle, $ring, $lensBrush, $band, $wb, $brush, $bg, $g) { $o.Dispose() }
    $bmp
}

function Get-DibBytes([System.Drawing.Bitmap]$Bmp) {
    # BITMAPINFOHEADER + bottom-up BGRA pixels + empty AND mask (alpha channel carries transparency)
    $size = $Bmp.Width
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $data = $Bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $pixels = New-Object byte[] ($stride * $size)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $Bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$size); $w.Write([int32]($size * 2))
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0)
    $w.Write([uint32]($size * $size * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($row = $size - 1; $row -ge 0; $row--) { $w.Write($pixels, $row * $stride, $size * 4) }
    $maskRow = [int]([Math]::Ceiling($size / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $size)))
    $w.Flush()
    # Unary comma: return the byte[] as one object instead of unrolling it into the pipeline
    , $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($sz in $sizes) {
    $bmp = New-IconBitmap $sz
    if ($sz -eq 256) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Save((Join-Path $OutFolder 'SQLMap.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    }
    else { $bytes = Get-DibBytes $bmp }
    $bmp.Dispose()
    [pscustomobject]@{ Size = $sz; Bytes = [byte[]]$bytes }
}

# ICONDIR + ICONDIRENTRY[] + image data
$ico = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($ico)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$img.Bytes.Length); $w.Write([uint32]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $w.Write($img.Bytes) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $OutFolder 'SQLMap.ico'), $ico.ToArray())

# Same design as SVG (used as the HTML report favicon/logo)
$svg = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2a78d6"/><stop offset="1" stop-color="#1c5cab"/></linearGradient></defs>
  <rect x="8" y="8" width="240" height="240" rx="52" fill="url(#g)"/>
  <rect x="46" y="66" width="124" height="112" fill="#fff"/>
  <ellipse cx="108" cy="66" rx="62" ry="20" fill="#fff"/>
  <ellipse cx="108" cy="178" rx="62" ry="20" fill="#fff"/>
  <ellipse cx="108" cy="66" rx="57.5" ry="15.5" fill="none" stroke="#2a78d6" stroke-width="9"/>
  <path d="M46 114a62 20 0 0 0 124 0M46 146a62 20 0 0 0 124 0" fill="none" stroke="#2a78d6" stroke-width="9"/>
  <circle cx="172" cy="172" r="42" fill="#1c5cab"/>
  <circle cx="172" cy="172" r="33" fill="none" stroke="#fff" stroke-width="18"/>
  <path d="M200 200l28 28" stroke="#fff" stroke-width="24" stroke-linecap="round"/>
</svg>
'@
[System.IO.File]::WriteAllText((Join-Path $OutFolder 'SQLMap.svg'), $svg, (New-Object System.Text.UTF8Encoding($false)))

Get-ChildItem $OutFolder -Filter 'SQLMap.*' | Select-Object Name, Length
