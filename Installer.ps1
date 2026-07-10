param(
    [switch]$Silent,   # run the install without showing the window (used for testing / quiet installs)
    [switch]$NoLaunch, # don't launch the app after installing
    [switch]$Test      # build the form, simulate toggling the checkboxes, print results, exit
)

# Daily To-Do — modern one-click installer (WinForms, dark theme).
# Copies the app into %LOCALAPPDATA%\DailyTodo\app, creates shortcuts, and
# (optionally) registers it to launch when Windows starts. No admin needed.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace Native -Name Win -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ReleaseCapture();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SendMessage(System.IntPtr hWnd, int msg, int wParam, int lParam);
"@

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- palette (matches the app) --------------------------------------------
$script:BG      = [System.Drawing.Color]::FromArgb(13, 13, 13)
$script:BGPanel = [System.Drawing.Color]::FromArgb(20, 20, 20)
$script:BGHover = [System.Drawing.Color]::FromArgb(30, 30, 30)
$script:FG      = [System.Drawing.Color]::FromArgb(212, 212, 212)
$script:FGDim   = [System.Drawing.Color]::FromArgb(120, 120, 120)
$script:Accent  = [System.Drawing.Color]::FromArgb(125, 191, 240)
$script:Border  = [System.Drawing.Color]::FromArgb(42, 42, 42)
$BG = $script:BG; $BGPanel = $script:BGPanel; $BGHover = $script:BGHover
$FG = $script:FG; $FGDim = $script:FGDim; $Accent = $script:Accent; $Border = $script:Border

$TitleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
$BodyFont  = New-Object System.Drawing.Font("Segoe UI", 10)
$SmallFont = New-Object System.Drawing.Font("Segoe UI", 9)
$BtnFont   = New-Object System.Drawing.Font("Segoe UI Semibold", 11)

$IconPath = Join-Path $ScriptDir "icon.ico"

# ---- install targets -------------------------------------------------------
$InstallRoot = Join-Path $env:LOCALAPPDATA "DailyTodo"
$AppDir      = Join-Path $InstallRoot "app"
$RuntimeFiles = @("DailyTodo.ps1", "storage.ps1", "DailyTodo.exe", "icon.ico", "Uninstall.ps1")

# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = "None"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(440, 340)
$form.BackColor = $BG
$form.Text = "Daily To-Do Setup"
$form.ShowInTaskbar = $true
if (Test-Path $IconPath) { try { $form.Icon = New-Object System.Drawing.Icon($IconPath) } catch {} }

# rounded corners + subtle border painted on the form
$form.Add_Shown({
    try { $r = 2; [void][Native.Win]::DwmSetWindowAttribute($form.Handle, 33, [ref]$r, 4) } catch {}
})
$form.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = "AntiAlias"
    $rect = New-Object System.Drawing.Rectangle(0, 0, ($form.Width - 1), ($form.Height - 1))
    $pen = New-Object System.Drawing.Pen $Border, 1
    $e.Graphics.DrawRectangle($pen, $rect)
    $pen.Dispose()
})

# ---- title bar (drag + close) ---------------------------------------------
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = "Top"; $bar.Height = 40; $bar.BackColor = $BG
$form.Controls.Add($bar)

$dragHandler = {
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][Native.Win]::ReleaseCapture()
        [void][Native.Win]::SendMessage($form.Handle, 0xA1, 0x2, 0)
    }
}
$bar.Add_MouseDown($dragHandler)

$close = New-Object System.Windows.Forms.Label
$close.Text = [char]0x2715
$close.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$close.ForeColor = $FGDim
$close.AutoSize = $false
$close.TextAlign = "MiddleCenter"
$close.Size = New-Object System.Drawing.Size(40, 40)
$close.Location = New-Object System.Drawing.Point(($form.Width - 40), 0)
$close.Cursor = "Hand"
$close.Add_MouseEnter({ $close.ForeColor = $FG })
$close.Add_MouseLeave({ $close.ForeColor = $FGDim })
$close.Add_Click({ $form.Close() })
$bar.Controls.Add($close)

# ---- title (left-aligned, no icon) ----------------------------------------
$title = New-Object System.Windows.Forms.Label
$title.Text = "Daily To-Do"
$title.Font = $TitleFont
$title.ForeColor = $FG
$title.AutoSize = $true
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(32, 52)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "A clean, console-style daily task list."
$subtitle.Font = $BodyFont
$subtitle.ForeColor = $FGDim
$subtitle.AutoSize = $true
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Location = New-Object System.Drawing.Point(34, 88)
$form.Controls.Add($subtitle)

# ---- custom modern checkbox factory ---------------------------------------
# State lives in $script:Checks keyed by the box's .Tag. Handlers are plain
# scriptblocks (NOT closures) so $script:Checks resolves to THIS script's scope;
# per-control identity is carried on .Tag instead of via captured variables.
$script:Checks = @{}

$script:BoxPaint = {
    param($s, $e)
    $e.Graphics.SmoothingMode = "AntiAlias"
    $on = [bool]$script:Checks[$s.Tag]
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 18; $arc = 6
    $gp.AddArc(0, 0, $arc, $arc, 180, 90)
    $gp.AddArc(($d - $arc), 0, $arc, $arc, 270, 90)
    $gp.AddArc(($d - $arc), ($d - $arc), $arc, $arc, 0, 90)
    $gp.AddArc(0, ($d - $arc), $arc, $arc, 90, 90)
    $gp.CloseFigure()
    if ($on) {
        $b = New-Object System.Drawing.SolidBrush $script:Accent
        $e.Graphics.FillPath($b, $gp); $b.Dispose()
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(13, 13, 13)), 2
        $pen.StartCap = "Round"; $pen.EndCap = "Round"
        $e.Graphics.DrawLines($pen, @(
            (New-Object System.Drawing.Point(4, 9)),
            (New-Object System.Drawing.Point(8, 13)),
            (New-Object System.Drawing.Point(14, 5))
        ))
        $pen.Dispose()
    } else {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 90, 90)), 1.5
        $e.Graphics.DrawPath($pen, $gp); $pen.Dispose()
    }
    $gp.Dispose()
}

# Clicking the box toggles directly; clicking the row/label forwards to its box
# (stored on the row's/label's .Tag).
$script:BoxClick = {
    param($s, $e)
    $script:Checks[$s.Tag] = -not [bool]$script:Checks[$s.Tag]
    $s.Invalidate()
}
$script:ProxyClick = {
    param($s, $e)
    $box = $s.Tag
    $script:Checks[$box.Tag] = -not [bool]$script:Checks[$box.Tag]
    $box.Invalidate()
}

function New-Check {
    param([string]$Key, [string]$Text, [int]$Top, [bool]$Checked)
    $script:Checks[$Key] = $Checked

    $row = New-Object System.Windows.Forms.Panel
    $row.Size = New-Object System.Drawing.Size(376, 30)
    $row.Location = New-Object System.Drawing.Point(32, $Top)
    $row.BackColor = $BG
    $row.Cursor = "Hand"

    $box = New-Object System.Windows.Forms.Panel
    $box.Size = New-Object System.Drawing.Size(20, 20)
    $box.Location = New-Object System.Drawing.Point(0, 5)
    $box.BackColor = $BG
    $box.Tag = $Key
    $box.Add_Paint($script:BoxPaint)
    $box.Add_Click($script:BoxClick)
    $row.Controls.Add($box)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = $BodyFont
    $lbl.ForeColor = $FG
    $lbl.AutoSize = $true
    $lbl.BackColor = $BG
    $lbl.Location = New-Object System.Drawing.Point(30, 6)
    $lbl.Tag = $box
    $lbl.Add_Click($script:ProxyClick)
    $row.Controls.Add($lbl)

    $row.Tag = $box
    $row.Add_Click($script:ProxyClick)

    $form.Controls.Add($row)
    return $row
}

$rowStartup = New-Check -Key "startup" -Text "Open automatically when Windows starts" -Top 132 -Checked $true
$rowDesktop = New-Check -Key "desktop" -Text "Create a desktop shortcut"               -Top 168 -Checked $true

# ---- status line -----------------------------------------------------------
$status = New-Object System.Windows.Forms.Label
$status.Text = ""
$status.Font = $SmallFont
$status.ForeColor = $FGDim
$status.AutoSize = $false
$status.TextAlign = "MiddleLeft"
$status.Size = New-Object System.Drawing.Size(240, 44)
$status.Location = New-Object System.Drawing.Point(32, 268)
$status.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($status)

# ---- Install button (custom, accent) --------------------------------------
$btn = New-Object System.Windows.Forms.Panel
$btn.Size = New-Object System.Drawing.Size(120, 42)
$btn.Location = New-Object System.Drawing.Point(288, 268)
$btn.BackColor = $Accent
$btn.Cursor = "Hand"
$form.Controls.Add($btn)

# Rounded corners for the button (clip the panel to a rounded-rect region).
$btnPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$bw = 120; $bh = 42; $dia = 20
$btnPath.AddArc(0, 0, $dia, $dia, 180, 90)
$btnPath.AddArc(($bw - $dia), 0, $dia, $dia, 270, 90)
$btnPath.AddArc(($bw - $dia), ($bh - $dia), $dia, $dia, 0, 90)
$btnPath.AddArc(0, ($bh - $dia), $dia, $dia, 90, 90)
$btnPath.CloseFigure()
$btn.Region = New-Object System.Drawing.Region($btnPath)

$btnLbl = New-Object System.Windows.Forms.Label
$btnLbl.Text = "Install"
$btnLbl.Font = $BtnFont
$btnLbl.ForeColor = [System.Drawing.Color]::FromArgb(13, 13, 13)
$btnLbl.Dock = "Fill"
$btnLbl.TextAlign = "MiddleCenter"
$btnLbl.BackColor = [System.Drawing.Color]::Transparent
$btn.Controls.Add($btnLbl)

$btn.Add_MouseEnter({ $btn.BackColor = [System.Drawing.Color]::FromArgb(150, 205, 245) })
$btn.Add_MouseLeave({ $btn.BackColor = $Accent })

# ---------------------------------------------------------------------------
function Set-Status { param([string]$Text, $Color = $FGDim) $status.ForeColor = $Color; $status.Text = $Text; $status.Refresh() }

function New-Shortcut {
    param([string]$Path, [string]$Target, [string]$Args, [string]$WorkDir, [string]$Ico)
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = $Target
    $sc.Arguments = $Args
    $sc.WorkingDirectory = $WorkDir
    $sc.WindowStyle = 7
    $sc.Description = "Daily To-Do list"
    if (Test-Path $Ico) { $sc.IconLocation = $Ico }
    $sc.Save()
}

function Do-Install {
    try {
        $btn.Enabled = $false; $btn.BackColor = [System.Drawing.Color]::FromArgb(70, 90, 105)
        Set-Status "Copying files..."

        if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
        foreach ($f in $RuntimeFiles) {
            $src = Join-Path $ScriptDir $f
            if (Test-Path $src) { Copy-Item $src -Destination (Join-Path $AppDir $f) -Force }
        }

        $launcher = Join-Path $AppDir "DailyTodo.exe"
        $ico      = Join-Path $AppDir "icon.ico"

        Set-Status "Creating shortcuts..."
        # Start Menu (always)
        $programs = [Environment]::GetFolderPath("Programs")
        New-Shortcut -Path (Join-Path $programs "Daily To-Do.lnk") -Target $launcher -Args "" -WorkDir $AppDir -Ico $ico

        # Desktop (optional)
        $desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Daily To-Do.lnk"
        if ($script:Checks["desktop"]) {
            New-Shortcut -Path $desktopLnk -Target $launcher -Args "" -WorkDir $AppDir -Ico $ico
        } elseif (Test-Path $desktopLnk) { Remove-Item $desktopLnk -Force -ErrorAction SilentlyContinue }

        # Startup (optional)
        $startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Daily To-Do.lnk"
        if ($script:Checks["startup"]) {
            New-Shortcut -Path $startupLnk -Target $launcher -Args "" -WorkDir $AppDir -Ico $ico
        } elseif (Test-Path $startupLnk) { Remove-Item $startupLnk -Force -ErrorAction SilentlyContinue }

        Set-Status "Registering..."
        # Register in Apps & features (per-user, no admin needed)
        $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DailyTodo"
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
        $uninstCmd = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $AppDir "Uninstall.ps1") + '"'
        Set-ItemProperty -Path $reg -Name "DisplayName"     -Value "Daily To-Do"
        Set-ItemProperty -Path $reg -Name "DisplayIcon"     -Value $ico
        Set-ItemProperty -Path $reg -Name "DisplayVersion"  -Value "1.0.0"
        Set-ItemProperty -Path $reg -Name "Publisher"       -Value "Daily To-Do"
        Set-ItemProperty -Path $reg -Name "InstallLocation" -Value $AppDir
        Set-ItemProperty -Path $reg -Name "UninstallString" -Value $uninstCmd
        Set-ItemProperty -Path $reg -Name "NoModify" -Value 1 -Type DWord
        Set-ItemProperty -Path $reg -Name "NoRepair" -Value 1 -Type DWord

        if (-not $NoLaunch) {
            Set-Status "Launching Daily To-Do..." $Accent
            Start-Process $launcher -WorkingDirectory $AppDir
        }
        if ($Silent) {
            Write-Host "Installed to $AppDir"
            Write-Host ("Startup: " + $script:Checks["startup"] + "  Desktop: " + $script:Checks["desktop"])
        } else {
            Start-Sleep -Milliseconds 700
        }
        $form.Close()
    } catch {
        if ($Silent) { Write-Host ("ERROR: " + $_.Exception.Message) }
        else {
            Set-Status ("Error: " + $_.Exception.Message) ([System.Drawing.Color]::FromArgb(240, 120, 120))
            $btn.Enabled = $true; $btn.BackColor = $Accent
        }
    }
}

$btn.Add_Click({ Do-Install })
$btnLbl.Add_Click({ Do-Install })

if ($Test) {
    foreach ($row in @($rowStartup, $rowDesktop)) {
        $key = $row.Tag.Tag
        $before = [bool]$script:Checks[$key]
        & $script:ProxyClick $row $null          # simulate clicking the row
        $mid = [bool]$script:Checks[$key]
        & $script:BoxClick $row.Tag $null         # simulate clicking the box
        $after = [bool]$script:Checks[$key]
        Write-Host ("{0}: {1} -> (row click) {2} -> (box click) {3}" -f $key, $before, $mid, $after)
    }
} elseif ($Silent) { Do-Install } else { [void]$form.ShowDialog() }
