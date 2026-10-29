param(
  [Parameter(Mandatory = $true)][string]$PayloadB64,
  [string]$DumpFrame = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('ToastNative' -as [type])) {
  Add-Type -Namespace '' -Name 'ToastNative' -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
}

if (-not ('LayeredApi' -as [type])) {
  Add-Type -Namespace '' -Name 'LayeredApi' -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
[DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hDC);
[DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);
[DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
[DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
[DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
[StructLayout(LayoutKind.Sequential, Pack = 1)] public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }
'@
}

$previousForeground = [IntPtr]::Zero
try { $previousForeground = [ToastNative]::GetForegroundWindow() } catch {}

$json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadB64))
$p = $json | ConvertFrom-Json

function Get-Prop($obj, $name, $default) {
  if ($null -eq $obj) { return $default }
  $v = $obj.PSObject.Properties[$name]
  if ($null -eq $v -or $null -eq $v.Value) { return $default }
  return $v.Value
}

function Get-Color($hex, $fallback) {
  if ([string]::IsNullOrWhiteSpace([string]$hex)) { return [System.Drawing.ColorTranslator]::FromHtml($fallback) }
  try {
    return [System.Drawing.ColorTranslator]::FromHtml([string]$hex)
  } catch {
    return [System.Drawing.ColorTranslator]::FromHtml($fallback)
  }
}

$title = [string](Get-Prop $p 'title' 'Harness')
$body = [string](Get-Prop $p 'body' '')
$meta = [string](Get-Prop $p 'meta' '')
$accent = [string](Get-Prop $p 'accent' '#4ADE80')
$seconds = [int](Get-Prop $p 'seconds' 8)
$width = [int](Get-Prop $p 'width' 340)
$offset = [int](Get-Prop $p 'offset' 0)
$margin = [int](Get-Prop $p 'margin' 8)
$sound = [bool](Get-Prop $p 'sound' $false)
$soundFile = [string](Get-Prop $p 'soundFile' 'Windows Notify System Generic.wav')
$fontFamily = [string](Get-Prop $p 'font' 'Microsoft YaHei UI')
$fontSize = [double](Get-Prop $p 'fontSize' 14)
$colors = Get-Prop $p 'colors' $null

$cardColor = Get-Color (Get-Prop $colors 'card' '#1F1F23') '#1F1F23'
$borderColor = Get-Color (Get-Prop $colors 'border' '#3A3A42') '#3A3A42'
$titleColor = Get-Color (Get-Prop $colors 'title' '#F2F2F5') '#F2F2F5'
$bodyColor = Get-Color (Get-Prop $colors 'body' '#C8C8D1') '#C8C8D1'
$metaColor = Get-Color (Get-Prop $colors 'meta' '#86868F') '#86868F'
$accentColor = Get-Color $accent '#4ADE80'

$fontSize = [Math]::Max(11, [Math]::Min(18, $fontSize))
$titlePt = [float]([Math]::Max(9.5, [Math]::Round($fontSize - 3.25, 1)))
$bodyPt = [float]([Math]::Max(9, [Math]::Round($fontSize - 4, 1)))
$metaPt = [float]([Math]::Max(8, [Math]::Round($fontSize - 5.25, 1)))

try {
  $titleFont = New-Object System.Drawing.Font($fontFamily, $titlePt, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
  $bodyFont = New-Object System.Drawing.Font($fontFamily, $bodyPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
  $metaFont = New-Object System.Drawing.Font($fontFamily, $metaPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
} catch {
  $fontFamily = 'Microsoft YaHei UI'
  $titleFont = New-Object System.Drawing.Font($fontFamily, $titlePt, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
  $bodyFont = New-Object System.Drawing.Font($fontFamily, $bodyPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
  $metaFont = New-Object System.Drawing.Font($fontFamily, $metaPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
}

$padLeft = 19
$padRight = 14
$padTop = 12
$padBottom = 12
$gap = 5
$textWidth = $width - $padLeft - $padRight
$maxBodyLines = 5

$measure = New-Object System.Drawing.Bitmap 8, 8
$mg = [System.Drawing.Graphics]::FromImage($measure)
$mg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$sfTitle = New-Object System.Drawing.StringFormat
$sfTitle.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
$sfTitle.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
$sfBody = New-Object System.Drawing.StringFormat
$sfBody.Trimming = [System.Drawing.StringTrimming]::EllipsisWord
$sfMeta = New-Object System.Drawing.StringFormat
$sfMeta.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
$sfMeta.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

$titleSize = $mg.MeasureString($title, $titleFont, (New-Object System.Drawing.SizeF($textWidth, 1000)), $sfTitle)
$titleHeight = [float][Math]::Ceiling($titleSize.Height)

$bodyHeight = 0
$bodyLineHeight = $bodyFont.GetHeight($mg)
if ($body.Length -gt 0) {
  $bodySize = $mg.MeasureString($body, $bodyFont, (New-Object System.Drawing.SizeF($textWidth, 9999)), $sfBody)
  $bodyHeight = [float][Math]::Ceiling([Math]::Min($bodySize.Height, $bodyLineHeight * $maxBodyLines))
}

$metaHeight = 0
if ($meta.Length -gt 0) { $metaHeight = [float][Math]::Ceiling($metaFont.GetHeight($mg)) }

$mg.Dispose()
$measure.Dispose()

$height = [int][Math]::Ceiling($padTop + $titleHeight + $gap + $bodyHeight + $gap + $metaHeight + $padBottom)

# ---- render the card once, supersampled ---------------------------------
$S = 1.0
$cardBmp = New-Object System.Drawing.Bitmap ([int]($width * $S)), ([int]($height * $S)), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$cardBmp.SetResolution(96, 96)
$cg = [System.Drawing.Graphics]::FromImage($cardBmp)
$cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$cg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$cg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$cg.ScaleTransform([float]$S, [float]$S)
$cg.Clear([System.Drawing.Color]::Transparent)

function New-RoundedPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$radius) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  $path.AddArc([float]$x, [float]$y, [float]$d, [float]$d, 180, 90)
  $path.AddArc([float]($x + $w - $d), [float]$y, [float]$d, [float]$d, 270, 90)
  $path.AddArc([float]($x + $w - $d), [float]($y + $h - $d), [float]$d, [float]$d, 0, 90)
  $path.AddArc([float]$x, [float]($y + $h - $d), [float]$d, [float]$d, 90, 90)
  $path.CloseFigure()
  return $path
}

$cardPath = New-RoundedPath 1 1 ($width - 2) ($height - 2) 10
$cardBrush = New-Object System.Drawing.SolidBrush $cardColor
$cg.FillPath($cardBrush, $cardPath)
$borderPen = New-Object System.Drawing.Pen $borderColor, 1
$cg.DrawPath($borderPen, $cardPath)

$cg.SetClip($cardPath)
$accentBrush = New-Object System.Drawing.SolidBrush $accentColor
$cg.FillRectangle($accentBrush, [float]0, [float]0, [float]3, [float]$height)
$cg.ResetClip()

$titleBrush = New-Object System.Drawing.SolidBrush $titleColor
$bodyBrush = New-Object System.Drawing.SolidBrush $bodyColor
$metaBrush = New-Object System.Drawing.SolidBrush $metaColor

$y = $padTop
$titleRect = New-Object System.Drawing.RectangleF ([float]$padLeft), ([float]$y), ([float]$textWidth), ([float]$titleHeight)
$cg.DrawString($title, $titleFont, $titleBrush, $titleRect, $sfTitle)
$y += $titleHeight

if ($bodyHeight -gt 0) {
  $y += $gap
  $bodyRect = New-Object System.Drawing.RectangleF ([float]$padLeft), ([float]$y), ([float]$textWidth), ([float]$bodyHeight)
  $cg.DrawString($body, $bodyFont, $bodyBrush, $bodyRect, $sfBody)
  $y += $bodyHeight
}

if ($metaHeight -gt 0) {
  $y += $gap
  $metaRect = New-Object System.Drawing.RectangleF ([float]$padLeft), ([float]$y), ([float]$textWidth), ([float]$metaHeight)
  $cg.DrawString($meta, $metaFont, $metaBrush, $metaRect, $sfMeta)
}

$cg.Dispose()

# ---- window -------------------------------------------------------------
$pad = 20
$frameW = $width + $pad * 2
$frameH = $height + $pad * 2

$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
# The card (not the transparent frame) sits $margin away from the taskbar edge.
$winX = $workArea.Right - $margin - $pad - $width
$winY = $workArea.Bottom - $margin - $pad - $height - $offset

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Text = 'Harness'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.Size = New-Object System.Drawing.Size($frameW, $frameH)
$form.Left = $winX
$form.Top = $winY
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

$handle = $form.Handle
$exStyle = [ToastNative]::GetWindowLong($handle, -20)
[void][ToastNative]::SetWindowLong($handle, -20, $exStyle -bor 0x00080000 -bor 0x08000000)

function Render-Frame([double]$shiftX, [double]$shiftY, [double]$alpha) {
  $bmp = New-Object System.Drawing.Bitmap $frameW, $frameH, ([System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
  $g.Clear([System.Drawing.Color]::Transparent)

  # Integer placement keeps the text pixel-exact: only position and alpha move.
  $x = [double]($pad + [Math]::Round($shiftX))
  $y = [double]($pad + [Math]::Round($shiftY))

  $shadowAlpha = [int][Math]::Round(20 * $alpha)
  if ($shadowAlpha -gt 0) {
    for ($layer = 3; $layer -ge 1; $layer--) {
      $shadowPath = New-RoundedPath ($x + 1) ($y + 1 + $layer * 0.9) $width $height 12
      $shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($shadowAlpha, 0, 0, 0))
      $g.FillPath($shadowBrush, $shadowPath)
      $shadowBrush.Dispose()
      $shadowPath.Dispose()
    }
  }

  # DrawImage has no (Image, RectangleF dest, Rectangle src, GraphicsUnit,
  # ImageAttributes) overload: PowerShell then picks the Point[] parallelogram
  # overload and dies converting the RectangleF. Keep one valid shape only -
  # integral destination, source = the whole supersampled card.
  $destRect = New-Object System.Drawing.Rectangle ([int]$x), ([int]$y), ([int]$width), ([int]$height)
  # Scale all four channels: the frame is premultiplied PArgb, so fading only
  # the alpha channel would leave RGB too bright and fringe the edges.
  $matrix = New-Object System.Drawing.Imaging.ColorMatrix
  $matrix.Matrix00 = [float]$alpha
  $matrix.Matrix11 = [float]$alpha
  $matrix.Matrix22 = [float]$alpha
  $matrix.Matrix33 = [float]$alpha
  $attributes = New-Object System.Drawing.Imaging.ImageAttributes
  $attributes.SetColorMatrix($matrix)
  $g.DrawImage($cardBmp, $destRect, 0, 0, $cardBmp.Width, $cardBmp.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
  $attributes.Dispose()

  $g.Dispose()
  return $bmp
}

function Push-Frame($bmp) {
  $screenDc = [LayeredApi]::GetDC([IntPtr]::Zero)
  $memDc = [LayeredApi]::CreateCompatibleDC($screenDc)
  $hBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  $oldBmp = [LayeredApi]::SelectObject($memDc, $hBmp)

  $ptDst = New-Object LayeredApi+POINT
  $ptDst.X = $winX
  $ptDst.Y = $winY
  $size = New-Object LayeredApi+SIZE
  $size.cx = $frameW
  $size.cy = $frameH
  $ptSrc = New-Object LayeredApi+POINT
  $blend = New-Object LayeredApi+BLENDFUNCTION
  $blend.BlendOp = 0
  $blend.BlendFlags = 0
  $blend.SourceConstantAlpha = 255
  $blend.AlphaFormat = 1

  $ok = [LayeredApi]::UpdateLayeredWindow($handle, $screenDc, [ref]$ptDst, [ref]$size, $memDc, [ref]$ptSrc, 0, [ref]$blend, 2)
  $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()

  [void][LayeredApi]::SelectObject($memDc, $oldBmp)
  [void][LayeredApi]::DeleteObject($hBmp)
  [void][LayeredApi]::DeleteDC($memDc)
  [void][LayeredApi]::ReleaseDC([IntPtr]::Zero, $screenDc)

  if (-not $ok) { throw "UpdateLayeredWindow failed (win32=$err)" }
}

function Show-Frame([double]$shiftX, [double]$shiftY, [double]$alpha) {
  $frame = Render-Frame $shiftX $shiftY $alpha
  Push-Frame $frame
  $frame.Dispose()
}

# ---- behaviour ----------------------------------------------------------
$script:alpha = 0.0
$script:alphaTarget = 1.0
$script:shift = 4.0
$script:shiftTarget = 0.0
$script:hoverLift = 0.0
$script:closing = $false

$closeForm = {
  if ($form.IsDisposed) { return }
  $keep.Stop()
  $hold.Stop()
  $anim.Stop()
  $form.Close()
}

$anim = New-Object System.Windows.Forms.Timer
$anim.Interval = 16
$anim.Add_Tick({
  $active = $false
  $da = $script:alphaTarget - $script:alpha
  if ([Math]::Abs($da) -gt 0.02) { $script:alpha += $da * 0.28; $active = $true }
  else { $script:alpha = $script:alphaTarget }
  $ds = $script:shiftTarget - $script:shift
  if ([Math]::Abs($ds) -gt 0.4) { $script:shift += $ds * 0.32; $active = $true }
  else { $script:shift = $script:shiftTarget }

  if ($form.IsDisposed) { $anim.Stop(); return }
  Show-Frame 0 ($script:shift + $script:hoverLift) $script:alpha
  if (-not $active) {
    $anim.Stop()
    if ($script:alphaTarget -le 0.02) { & $closeForm }
  }
})

$baseHoldMs = [Math]::Max(800, $seconds * 1000)
$hold = New-Object System.Windows.Forms.Timer
$hold.Interval = $baseHoldMs
$hold.Add_Tick({
  $hold.Stop()
  $script:closing = $true
  $script:alphaTarget = 0.0
  $anim.Start()
})

$keep = New-Object System.Windows.Forms.Timer
$keep.Interval = 700
$keep.Add_Tick({
  if ($form.IsDisposed) { return }
  [void][ToastNative]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
})

$onEnter = {
  if ($script:closing) { return }
  # Hover only lifts the card; the countdown is never touched, so the card can
  # neither be pinned forever by a resting cursor nor cut short.
  $script:hoverLift = -2.0
  if (-not $form.IsDisposed) { Show-Frame 0 ($script:shift + $script:hoverLift) $script:alpha }
}

$onLeave = {
  if ($script:closing) { return }
  $script:hoverLift = 0.0
  if (-not $form.IsDisposed) { Show-Frame 0 ($script:shift + $script:hoverLift) $script:alpha }
}

$onDown = {
  if ($script:closing) { return }
  $script:closing = $true
  $script:hoverLift = 1.0
  $script:alphaTarget = 0.0
  $anim.Start()
}

$form.Add_MouseEnter($onEnter)
$form.Add_MouseLeave($onLeave)
$form.Add_MouseDown($onDown)

$form.Add_Shown({
  [void][ToastNative]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
  $keep.Start()
  if ($DumpFrame) {
    $probe = Render-Frame 0 0 1.0
    $probe.Save($DumpFrame, [System.Drawing.Imaging.ImageFormat]::Png)
    $probe.Dispose()
  }
  Show-Frame 0 ($script:shift + $script:hoverLift) $script:alpha
  $anim.Start()
  $hold.Start()
  try {
    if ($previousForeground -ne [IntPtr]::Zero -and [ToastNative]::GetForegroundWindow() -eq $form.Handle) {
      [void][ToastNative]::SetForegroundWindow($previousForeground)
    }
  } catch {}
  if ($sound) {
    try {
      $wav = Join-Path (Join-Path $env:SystemRoot 'Media') $soundFile
      if (Test-Path -LiteralPath $wav) {
        $script:player = New-Object System.Media.SoundPlayer $wav
        $script:player.Play()
      } else {
        [void][System.Media.SystemSounds]::Asterisk.Play()
      }
    } catch {
      try { [void][System.Media.SystemSounds]::Asterisk.Play() } catch {}
    }
  }
})

[System.Windows.Forms.Application]::Run($form)
$cardBmp.Dispose()
