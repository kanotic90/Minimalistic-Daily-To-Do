# Daily To-Do — dark console-style task list (WinForms)
#
# HOW THIS FILE IS ORGANIZED (top to bottom):
#   1. Native interop (P/Invoke) + a mouse-wheel message filter.
#   2. Palette / fonts / TUNABLES  — the knobs you'll usually want to tweak.
#   3. Script-level state (drag, fades, scroll, inline-edit, undo stack).
#   4. Form + child controls (header, list panel, input bar, scroll bar).
#   5. Helpers: rounded-region paths, row hover, fades, inline edit, drag,
#      slide, scroll, and the list (re)build/relayout functions.
#   6. Event wiring + the Application.Idle render loop that drives every
#      animation at the display's refresh rate.
#
# ANIMATION MODEL: nothing animates on its own timer. Active animations set a
# flag (e.g. $script:ScrollActive) and the single Idle render loop calls
# Animate-Frame repeatedly — yielding via PeekMessage — so drag/scroll/fade/
# slide all run smoothly together. Timings live in $script:Anim (see TUNABLES).
#
# DATA: tasks persist to todos.json via storage.ps1 (Get/Save/Toggle/Set-Todo*).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace Native -Name Win -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SendMessage(System.IntPtr hWnd, int msg, bool wParam, int lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="SendMessage")]
public static extern int SendMessageInt(System.IntPtr hWnd, int msg, int wParam, int lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint="SendMessage")]
public static extern System.IntPtr SendMessagePtr(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern int SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
[System.Runtime.InteropServices.DllImport("winmm.dll")]
public static extern uint timeBeginPeriod(uint uMilliseconds);
[System.Runtime.InteropServices.DllImport("winmm.dll")]
public static extern uint timeEndPeriod(uint uMilliseconds);
"@

# PeekMessage lets the high-frame-rate drag loop yield the moment real input
# (mouse/keyboard) is waiting, so a busy render loop never freezes the UI.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMsg {
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max, uint remove);
    public static bool AnyMessage() { MSG m; return PeekMessage(out m, IntPtr.Zero, 0, 0, 0); }
}
"@

# Message filter so the mouse wheel scrolls the list when hovered, regardless of focus.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
public class WheelFilter : IMessageFilter {
    public Func<Point, bool> IsOverList;
    public Action<int> OnWheel;
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == 0x020A) { // WM_MOUSEWHEEL
            int delta = (short)((long)m.WParam >> 16);
            Point p = Cursor.Position;
            if (IsOverList != null && IsOverList(p)) {
                if (OnWheel != null) OnWheel(delta);
                return true;
            }
        }
        return false;
    }
}

// A task's text lives in one of these for its whole life. When EditMode is
// false it acts like a static label (no caret, no selection, no focus) and just
// forwards clicks/right-clicks to the row so hover/drag/complete/edit all work.
// Flip EditMode on and it's an ordinary editable TextBox. Because the SAME
// control renders the text in both states, editing causes zero visual change.
public class TaskTextBox : TextBox {
    public bool EditMode = false;
    const int WM_SETFOCUS = 0x0007, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202,
              WM_LBUTTONDBLCLK = 0x0203, WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205,
              WM_CONTEXTMENU = 0x007B;
    protected override void WndProc(ref Message m) {
        if (!EditMode) {
            switch (m.Msg) {
                case WM_SETFOCUS:            // never focus in display mode -> no caret
                    return;
                case WM_CONTEXTMENU:         // suppress the native right-click menu
                    return;
                case WM_LBUTTONDOWN:
                case WM_LBUTTONDBLCLK:
                    OnMouseDown(MakeArgs(MouseButtons.Left, m.LParam)); return;
                case WM_LBUTTONUP:
                    OnMouseUp(MakeArgs(MouseButtons.Left, m.LParam)); return;
                case WM_RBUTTONDOWN:
                    OnMouseDown(MakeArgs(MouseButtons.Right, m.LParam)); return;
                case WM_RBUTTONUP:
                    OnMouseUp(MakeArgs(MouseButtons.Right, m.LParam)); return;
            }
        }
        base.WndProc(ref m);   // WM_MOUSEMOVE etc. still flow so hover works
    }
    private MouseEventArgs MakeArgs(MouseButtons b, IntPtr lp) {
        int v = lp.ToInt32();
        return new MouseEventArgs(b, 1, (short)(v & 0xFFFF), (short)((v >> 16) & 0xFFFF), 0);
    }
}
"@

# Give the app its own taskbar identity so Windows uses the window icon (Sobble)
# instead of the host PowerShell logo.
try { [Native.Win]::SetCurrentProcessExplicitAppUserModelID("DailyToDo.App") | Out-Null } catch { }

. "$PSScriptRoot\storage.ps1"

# Console-inspired palette
$script:BG        = [System.Drawing.Color]::FromArgb(13, 13, 13)
$script:BGPanel   = [System.Drawing.Color]::FromArgb(20, 20, 20)
$script:BGHover   = [System.Drawing.Color]::FromArgb(22, 22, 22)
$script:FG        = [System.Drawing.Color]::FromArgb(212, 212, 212)
$script:FGDim     = [System.Drawing.Color]::FromArgb(110, 110, 110)
$script:Accent    = [System.Drawing.Color]::FromArgb(78, 201, 176)
$script:HoverText = [System.Drawing.Color]::FromArgb(125, 191, 240)
$script:Border    = [System.Drawing.Color]::FromArgb(42, 42, 42)

$script:MonoFont      = New-Object System.Drawing.Font("Consolas", 10)
$script:MonoFontHover = New-Object System.Drawing.Font("Consolas", 11)
$script:UIFont   = New-Object System.Drawing.Font("Segoe UI", 10)
$script:TitleFont = New-Object System.Drawing.Font("Segoe UI", 13)
$script:DateFont  = New-Object System.Drawing.Font("Segoe UI", 11)
$script:Bullet = [char]0x2022
$script:BulletWidth = 18

# ---------------------------------------------------------------------------
# TUNABLES — change look/feel here instead of hunting through the code below.
#   * Palette + fonts are defined just above.
#   * RowGap / CornerRadius (defined near the form) control geometry.
#   * $Anim holds animation timings in SECONDS. Fades use a fixed duration;
#     Drag/Slide/Scroll glides use an exponential ease whose value is the
#     time-constant "tau" (smaller = snappier). Every animation is driven by
#     the shared high-frame-rate render loop (see the Application.Idle handler).
# ---------------------------------------------------------------------------
$script:RowGap = 6                 # vertical pixels between task rows
$script:Anim = @{
    FadeOut   = 0.22   # a task fading to black when checked off
    FadeIn    = 0.20   # a task (new or undone) fading in
    DragTau   = 0.045  # other rows easing aside while you drag one
    SlideTau  = 0.045  # rows sliding down when an undo restores a task
    ScrollTau = 0.050  # momentum-scroll glide toward the target offset
    LenDur    = 0.15   # scrollbar length change (ease-out; ~25% longer than before)
}

$script:AnimatingIds = @{}
$script:FadeInIds = @{}
$script:UndoStack = New-Object System.Collections.Generic.Stack[object]

# Drag-to-reorder state
$script:DragPending    = $false
$script:DragActive     = $false
$script:DragSettling   = $false
$script:DragRow        = $null
$script:DragCandidate  = $null
$script:DragOrder      = @()
$script:DragThreshold  = 5
$script:DragIndex      = 0
$script:DragOffsetY    = 0
$script:DragDesiredTop = 0
$script:DragDir        = 1
$script:DragLastCenter = 0.0
$script:DragClock      = New-Object System.Diagnostics.Stopwatch
$script:DragStartScreen = New-Object System.Drawing.Point(0, 0)
# Set when a left-click both exits edit mode AND begins a drag, so the mouse-up
# for that same click doesn't also check the task off.
$script:SuppressNextComplete = $false

# Generic row-slide animation (e.g. rows sliding down when a task is restored)
$script:SlideActive = $false
$script:SlideClock  = New-Object System.Diagnostics.Stopwatch

# Active text fades (complete/add/undo), driven by the high-frame-rate loop.
$script:Fades = New-Object System.Collections.ArrayList

# Inline edit (right-click a task) state
$script:Editing     = $false
$script:EditRowId   = $null
$script:EditBox     = $null
$script:EditOldText = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = "Daily To-Do"
$form.BackColor = $script:BG
$form.ForeColor = $script:FG
$form.ClientSize = New-Object System.Drawing.Size(380, 520)
$form.MinimumSize = New-Object System.Drawing.Size(320, 400)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $true
$form.MaximizeBox = $false
$script:CornerRadius = 8
# 1px inset so the gray border ring is visible around the docked content.
$form.Padding = New-Object System.Windows.Forms.Padding(1)

# Taskbar icon (Sobble) — only if an icon.ico has been generated. Keep the Icon
# objects in script scope so their native handles aren't garbage-collected (which
# can make the taskbar quietly fall back to the PowerShell host icon).
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
if (Test-Path $iconPath) {
    try {
        $script:AppIcon      = New-Object System.Drawing.Icon($iconPath)
        $script:AppIconBig   = New-Object System.Drawing.Icon($iconPath, 32, 32)
        $script:AppIconSmall = New-Object System.Drawing.Icon($iconPath, 16, 16)
        $form.Icon = $script:AppIcon
    } catch { }
}

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 36
$header.BackColor = $script:BG

$title = New-Object System.Windows.Forms.Label
$title.Text = "today"
$title.Font = $script:TitleFont
$title.ForeColor = $script:FG
$title.BackColor = $script:BG
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 8)

$dateLabel = New-Object System.Windows.Forms.Label
$dateLabel.Text = (Get-Date -Format "M/d")
$dateLabel.Font = $script:DateFont
$dateLabel.ForeColor = $script:HoverText
$dateLabel.BackColor = $script:BG
$dateLabel.AutoSize = $true
$dateLabel.Anchor = "Top,Right"
$dateLabel.Location = New-Object System.Drawing.Point(0, 13)

# Custom close button (no OS title bar). Small square with a gray border box.
$script:CloseHover = $false
$closeBtn = New-Object System.Windows.Forms.Panel
$closeBtn.Size = New-Object System.Drawing.Size(20, 20)
$closeBtn.BackColor = $script:BG
$closeBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$closeBtn.Anchor = "Top,Right"

$closeBtn.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    if ($script:CloseHover) {
        $bgBrush = New-Object System.Drawing.SolidBrush $script:BGHover
        $g.FillRectangle($bgBrush, 0, 0, $sender.Width, $sender.Height)
        $bgBrush.Dispose()
    }
    # Gray border box (same color as the divider).
    $pen = New-Object System.Drawing.Pen $script:Border, 1
    $g.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
    $pen.Dispose()
    # Centered X.
    $xColor = if ($script:CloseHover) { $script:FG } else { $script:FGDim }
    $xBrush = New-Object System.Drawing.SolidBrush $xColor
    $xFont  = New-Object System.Drawing.Font("Segoe UI", 9)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0, 0, $sender.Width, $sender.Height)
    $g.DrawString("x", $xFont, $xBrush, $rect, $sf)
    $xBrush.Dispose(); $xFont.Dispose(); $sf.Dispose()
})
$closeBtn.Add_MouseEnter({ $script:CloseHover = $true; $closeBtn.Invalidate() })
$closeBtn.Add_MouseLeave({ $script:CloseHover = $false; $closeBtn.Invalidate() })
$closeBtn.Add_Click({ $form.Close() })

$header.Controls.AddRange(@($title, $dateLabel, $closeBtn))

# --- Drag the window by the header (no title bar) ---
$script:Dragging = $false
$script:DragOffset = New-Object System.Drawing.Point(0, 0)
$dragDown = {
    param($sender, $e)
    if ($script:Editing) { Commit-Edit }
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Dragging = $true
        $script:DragOffset = $e.Location
        if ($sender -eq $title) {
            $script:DragOffset = New-Object System.Drawing.Point(($e.X + $title.Left), ($e.Y + $title.Top))
        }
    }
}
$dragMove = {
    param($sender, $e)
    if ($script:Dragging) {
        $screen = [System.Windows.Forms.Cursor]::Position
        $form.Location = New-Object System.Drawing.Point(($screen.X - $script:DragOffset.X), ($screen.Y - $script:DragOffset.Y))
    }
}
$dragUp = {
    param($sender, $e)
    $script:Dragging = $false
}
$header.Add_MouseDown($dragDown)
$header.Add_MouseMove($dragMove)
$header.Add_MouseUp($dragUp)
$title.Add_MouseDown($dragDown)
$title.Add_MouseMove($dragMove)
$title.Add_MouseUp($dragUp)

$dividerTop = New-Object System.Windows.Forms.Panel
$dividerTop.Dock = "Top"
$dividerTop.Height = 1
$dividerTop.BackColor = $script:Border

$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Dock = "Fill"
$listPanel.BackColor = $script:BG
$listPanel.AutoScroll = $false
# Clicking empty space in the list exits edit mode.
$listPanel.Add_MouseDown({ if ($script:Editing) { Commit-Edit } })

# Double-buffer the list so rebuilding/scrolling rows doesn't flicker.
try {
    $dbProp = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
        [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
    $dbProp.SetValue($listPanel, $true, $null)
} catch { }

# Layout margins for the list (native scrollbar is replaced by a custom one).
$script:ListLeft      = 20
$script:ListTop       = 6
$script:ListBottom    = 8
$script:ScrollWidth   = 3            # hit-test width of the bar panel
$script:ThumbWidth    = 2.25         # drawn thumb width (25% thinner than the old 3px)
$script:ScrollRightPad = 9           # inset from the right edge so it doesn't crowd the corner
$script:ScrollInsetY  = 6            # keep the rounded thumb ends clear of the window's rounded corners
$script:RightGutter   = $script:ScrollWidth + $script:ScrollRightPad + 6
$script:ScrollOffset  = 0
$script:ContentHeight = 0
$script:ScrollAlpha       = 0    # current thumb opacity (0-220)
$script:ScrollTargetAlpha = 0    # opacity to animate toward
$script:ScrollMaxAlpha    = 220
$script:ScrollThumbRGB    = 209  # thumb grey, 5% dimmer than the old 220
$script:DisplayContent    = 0    # animated content height (drives thumb SIZE)
$script:DisplayOffset     = 0.0  # animated scroll offset (drives thumb POSITION during a resize)
$script:ScrollReady       = $false

# Smooth (eased) wheel scrolling — animates toward a target at high frame rate.
$script:ScrollActive = $false
$script:ScrollTarget = 0.0       # where the wheel wants us to be
$script:ScrollPos    = 0.0       # fractional current offset being eased
$script:ScrollClock  = New-Object System.Diagnostics.Stopwatch
# Cap the momentum scroll's repaint rate. The glide itself stays time-based, so
# capping only limits how often we repaint the rows + thumb (keeps CPU sane and
# pacing consistent). 240 fps of scroll/text updates.
$script:ScrollMinFrame  = 1.0 / 240.0
$script:ScrollFrameClock = [System.Diagnostics.Stopwatch]::StartNew()

# Thumb length (size) animation — time-based ease-out driven by the shared
# high-frame-rate render loop (see Len-Frame). Fast start, gentle finish.
# Both the content height (size) and the scroll offset (position) are eased with
# the same clock/curve so the thumb morphs consistently: whichever end you're at
# stays pinned and only its length changes — no bounce anywhere in the track.
$script:LenActive = $false
$script:LenStart        = 0.0   # content height at animation start
$script:LenTarget       = 0.0   # content height to ease toward
$script:LenStartOffset  = 0.0   # scroll offset at animation start
$script:LenTargetOffset = 0.0   # scroll offset to ease toward
$script:LenClock  = New-Object System.Diagnostics.Stopwatch

$emptyLabel = New-Object System.Windows.Forms.Label
$emptyLabel.Text = "nothing here yet"
$emptyLabel.Font = $script:MonoFont
$emptyLabel.ForeColor = $script:FGDim
$emptyLabel.BackColor = $script:BG
$emptyLabel.AutoSize = $true
$emptyLabel.Location = New-Object System.Drawing.Point($script:ListLeft, 8)
$listPanel.Controls.Add($emptyLabel)

# Custom minimalist scrollbar: a thin white bar whose length is proportional to
# the visible fraction of the list. Drawn on the right edge of the list.
$scrollBar = New-Object System.Windows.Forms.Panel
$scrollBar.Width = $script:ScrollWidth
$scrollBar.BackColor = $script:BG
$scrollBar.Cursor = [System.Windows.Forms.Cursors]::Hand
try { $dbProp.SetValue($scrollBar, $true, $null) } catch { }
$listPanel.Controls.Add($scrollBar)

$scrollBar.Add_Paint({
    param($sender, $e)
    if ($script:ScrollAlpha -le 0) { return }
    $viewport = $listPanel.ClientSize.Height
    # Size and position are derived from the SAME (animating) content + offset so
    # the thumb morphs consistently. During a resize both are eased in lockstep
    # (see Len-Frame): the end you're at stays pinned, only the length changes.
    $content = [double]$script:DisplayContent
    $offset  = if ($script:LenActive) { $script:DisplayOffset } else { [double]$script:ScrollOffset }
    $trackTop = $script:ListTop + $script:ScrollInsetY
    $trackH   = $sender.Height - $script:ListTop - $script:ListBottom - (2 * $script:ScrollInsetY)
    if ($trackH -le 0) { return }

    if ($content -le $viewport -or $content -le 0) {
        $thumbY = $trackTop
        $thumbH = $trackH
    } else {
        $ratio = $viewport / $content
        $thumbH = [int]([Math]::Max(24, $trackH * $ratio))
        $denom = $content - $viewport
        $frac = if ($denom -gt 0) { $offset / $denom } else { 0 }
        if ($frac -lt 0) { $frac = 0 }
        if ($frac -gt 1) { $frac = 1 }
        $thumbY = $trackTop + [int](($trackH - $thumbH) * $frac)
    }

    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $a = [Math]::Max(0, [Math]::Min(255, $script:ScrollAlpha))
    $c = $script:ScrollThumbRGB
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, $c, $c, $c))
    $tw = [double]$script:ThumbWidth
    $tx = ($sender.Width - $tw) / 2.0        # center the thin thumb in the panel
    $path = New-CapsulePathF $tx $thumbY $tw $thumbH
    $g.FillPath($brush, $path)
    $path.Dispose()
    $brush.Dispose()
})

# Dragging the bar scrolls the list.
$script:ScrollDrag = $false
$script:ScrollDragStartY = 0
$script:ScrollDragStartOffset = 0
$scrollBar.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:ScrollActive = $false   # cancel any wheel momentum while dragging the bar
    $maxScroll = Get-MaxScroll
    if ($maxScroll -le 0) { return }
    $viewport = $listPanel.ClientSize.Height
    $trackTop = $script:ListTop + $script:ScrollInsetY
    $trackH = $sender.Height - $script:ListTop - $script:ListBottom - (2 * $script:ScrollInsetY)
    $ratio = [double]$viewport / [double]$script:ContentHeight
    $thumbH = [int]([Math]::Max(24, $trackH * $ratio))
    $frac = [double]$script:ScrollOffset / $maxScroll
    $thumbY = $trackTop + [int](($trackH - $thumbH) * $frac)
    # If the press is off the thumb, jump so the thumb centers on the cursor.
    if ($e.Y -lt $thumbY -or $e.Y -gt ($thumbY + $thumbH)) {
        $targetFrac = [double]($e.Y - $trackTop - ($thumbH / 2)) / [Math]::Max(1, ($trackH - $thumbH))
        Set-ScrollFraction $targetFrac
    }
    $script:ScrollDrag = $true
    $script:ScrollDragStartY = $e.Y
    $script:ScrollDragStartOffset = $script:ScrollOffset
})
$scrollBar.Add_MouseMove({
    param($sender, $e)
    if (-not $script:ScrollDrag) { return }
    $maxScroll = Get-MaxScroll
    if ($maxScroll -le 0) { return }
    $viewport = $listPanel.ClientSize.Height
    $trackH = $sender.Height - $script:ListTop - $script:ListBottom - (2 * $script:ScrollInsetY)
    $ratio = [double]$viewport / [double]$script:ContentHeight
    $thumbH = [int]([Math]::Max(24, $trackH * $ratio))
    $span = [Math]::Max(1, ($trackH - $thumbH))
    $deltaOffset = [int](($e.Y - $script:ScrollDragStartY) * ($maxScroll / $span))
    Set-ScrollOffset ($script:ScrollDragStartOffset + $deltaOffset)
})
$scrollBar.Add_MouseUp({ $script:ScrollDrag = $false })

$dividerBottom = New-Object System.Windows.Forms.Panel
$dividerBottom.Dock = "Bottom"
$dividerBottom.Height = 1
$dividerBottom.BackColor = $script:Border

$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Dock = "Bottom"
$inputPanel.Height = 52
$inputPanel.BackColor = $script:BGPanel
$inputPanel.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
$inputPanel.Add_MouseDown({ if ($script:Editing) { Commit-Edit } })

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Dock = "Fill"
$inputBox.Font = $script:MonoFont
$inputBox.BackColor = $script:BGPanel
$inputBox.ForeColor = $script:FGDim
$inputBox.BorderStyle = "None"
$inputBox.Text = "add a task..."
# Don't let the input box become the fallback focus (and blink a caret) when the
# inline edit box is disposed. A mouse click still focuses it for typing.
$inputBox.TabStop = $false
$script:HasPlaceholder = $true

$addBtn = New-Object System.Windows.Forms.Label
$addBtn.Text = "+"
$addBtn.Font = New-Object System.Drawing.Font("Segoe UI", 16)
$addBtn.ForeColor = $script:Accent
$addBtn.BackColor = $script:BGPanel
$addBtn.AutoSize = $true
$addBtn.Dock = "Right"
$addBtn.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$addBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$inputPanel.Controls.Add($inputBox)
$inputPanel.Controls.Add($addBtn)

$form.Controls.Add($listPanel)
$form.Controls.Add($dividerBottom)
$form.Controls.Add($inputPanel)
$form.Controls.Add($dividerTop)
$form.Controls.Add($header)

$script:LastMtime = $null
$script:RowControls = @()

function Clear-Placeholder {
    if ($script:HasPlaceholder) {
        $inputBox.Text = ""
        $inputBox.ForeColor = $script:FG
        $script:HasPlaceholder = $false
    }
}

function Restore-Placeholder {
    if ([string]::IsNullOrWhiteSpace($inputBox.Text)) {
        $inputBox.Text = "add a task..."
        $inputBox.ForeColor = $script:FGDim
        $script:HasPlaceholder = $true
    }
}

function Add-TaskFromInput {
    Clear-Placeholder
    $text = $inputBox.Text.Trim()
    if (-not $text) { return }
    $new = @(Add-Todo $text) | Where-Object { $_.id } | Select-Object -Last 1
    if ($new) { $script:FadeInIds[[string]$new.id] = $true }
    $inputBox.Text = ""
    Restore-Placeholder
    $script:LastMtime = Get-TodoFileMtime
    Update-List
}

function Blend-Color {
    param($from, $to, [double]$t)
    if ($t -lt 0) { $t = 0 }
    if ($t -gt 1) { $t = 1 }
    $r = [int]($from.R + ($to.R - $from.R) * $t)
    $g = [int]($from.G + ($to.G - $from.G) * $t)
    $b = [int]($from.B + ($to.B - $from.B) * $t)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Get-RowFromSender {
    param($sender)
    if ($sender.Name -eq 'row') { return $sender }
    return $sender.Parent
}

function Find-RowById {
    param([string]$Id)
    foreach ($r in $script:RowControls) {
        if ([string]$r.Tag -eq [string]$Id) { return $r }
    }
    return $null
}

function Set-DoubleBuffered {
    param($ctl)
    try {
        $p = [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        $p.SetValue($ctl, $true, $null)
    } catch { }
}

# Rounded hover highlight, painted behind the (transparent) row contents.
$script:RowPaint = {
    param($sender, $e)
    if (-not $sender.Hovered) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundedRectPath 0 0 $sender.Width $sender.Height $script:CornerRadius
    $brush = New-Object System.Drawing.SolidBrush $script:BGHover
    $g.FillPath($brush, $path)
    $brush.Dispose()
    $path.Dispose()
}

function Enter-Row {
    param($row)
    if ($null -eq $row) { return }
    if ($script:DragActive -or $script:DragSettling) { return }
    if ($script:Editing -and [string]$row.Tag -eq [string]$script:EditRowId) { return }
    if ($script:AnimatingIds.ContainsKey([string]$row.Tag)) { return }
    $row.Hovered = $true
    $row.Invalidate($true)
    foreach ($c in $row.Controls) {
        if ($c.Name -eq 'label') { $c.ForeColor = $script:HoverText; $c.BackColor = $script:BGHover }
    }
}

function Leave-Row {
    param($row)
    if ($null -eq $row) { return }
    if ($script:DragActive -or $script:DragSettling) { return }
    if ($script:Editing -and [string]$row.Tag -eq [string]$script:EditRowId) { return }
    $pos = $row.PointToClient([System.Windows.Forms.Cursor]::Position)
    if ($row.ClientRectangle.Contains($pos)) { return }
    if ($script:AnimatingIds.ContainsKey([string]$row.Tag)) { return }
    $row.Hovered = $false
    $row.Invalidate($true)
    foreach ($c in $row.Controls) {
        if ($c.Name -eq 'label') { $c.ForeColor = $script:FG; $c.BackColor = $script:BG }
    }
}

# Re-evaluate which row the cursor is over and apply the highlight, without
# needing a mouse move (used after Ctrl+Z so a hovered row lights up right away).
function Refresh-Hover {
    if ($script:DragActive -or $script:DragSettling) { return }
    foreach ($r in $script:RowControls) {
        $p = $r.PointToClient([System.Windows.Forms.Cursor]::Position)
        if ($r.ClientRectangle.Contains($p)) { Enter-Row $r } else { Leave-Row $r }
    }
}

function Ease-InOut {
    param([double]$t)
    if ($t -lt 0) { $t = 0 }
    if ($t -gt 1) { $t = 1 }
    return ($t * $t * (3.0 - 2.0 * $t))   # smoothstep — gentle start and finish
}

function Register-Fade {
    param($fade)
    [void]$script:Fades.Add($fade)
    if (-not $dragTimer.Enabled) { $dragTimer.Start() }
}

function Start-FadeOut {
    param($row, $bullet, $label, $id)
    if ($script:AnimatingIds.ContainsKey([string]$id)) { return }
    $script:AnimatingIds[[string]$id] = $true

    # Clear hover highlight so the text fades cleanly into black
    $row.Hovered = $false
    $row.Invalidate($true)
    $label.BackColor = $script:BG

    Register-Fade @{
        Kind       = 'out'
        Id         = [string]$id
        Label      = $label
        Bullet     = $bullet
        LabelFrom  = $label.ForeColor
        LabelTo    = $script:BG
        BulletFrom = $bullet.ForeColor
        BulletTo   = $script:BG
        Duration   = $script:Anim.FadeOut
        Clock      = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Start-FadeIn {
    param($row, $bullet, $label, $id)
    $script:AnimatingIds[[string]$id] = $true

    # Start invisible (text = background), then fade up to the real colors.
    $label.ForeColor  = $script:BG
    $bullet.ForeColor = $script:BG

    Register-Fade @{
        Kind       = 'in'
        Id         = [string]$id
        Label      = $label
        Bullet     = $bullet
        LabelFrom  = $script:BG
        LabelTo    = $script:FG
        BulletFrom = $script:BG
        BulletTo   = $script:FGDim
        Duration   = $script:Anim.FadeIn
        Clock      = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

# One high-frame-rate step of every active text fade. Colors are eased with
# smoothstep for a satisfying, buttery transition; each label is refreshed
# immediately so the color updates at the render loop's rate, not ~100Hz.
function Fade-Frame {
    if ($script:Fades.Count -eq 0) { return $false }
    $done = New-Object System.Collections.ArrayList
    foreach ($f in @($script:Fades)) {
        $raw = $f.Clock.Elapsed.TotalSeconds / $f.Duration
        if ($raw -ge 1) { $raw = 1 }
        $t = Ease-InOut $raw
        try {
            $f.Label.ForeColor  = Blend-Color $f.LabelFrom  $f.LabelTo  $t
            $f.Bullet.ForeColor = Blend-Color $f.BulletFrom $f.BulletTo $t
            $f.Label.Refresh()
            $f.Bullet.Refresh()
        } catch { }
        if ($raw -ge 1) { [void]$done.Add($f) }
    }
    foreach ($f in $done) {
        $script:Fades.Remove($f)
        Complete-Fade $f
    }
    return $true
}

function Complete-Fade {
    param($f)
    if ($f.Kind -eq 'out') {
        Toggle-Todo $f.Id
        $script:UndoStack.Push([pscustomobject]@{ Kind = 'complete'; Id = [string]$f.Id })
        $script:AnimatingIds.Remove([string]$f.Id)
        $script:LastMtime = Get-TodoFileMtime
        Update-List
    } else {
        try { $f.Label.ForeColor = $f.LabelTo; $f.Bullet.ForeColor = $f.BulletTo } catch { }
        $script:AnimatingIds.Remove([string]$f.Id)
        Refresh-Hover
    }
}

# ---- Inline edit (right-click a task) ---------------------------------------

$script:EditKeyDown = {
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return -and -not $e.Shift) {
        $e.SuppressKeyPress = $true
        Commit-Edit
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $e.SuppressKeyPress = $true
        Cancel-Edit
    }
}
$script:EditLostFocus = { if ($script:Editing) { Commit-Edit } }

function Begin-Edit {
    param($row)
    if ($null -eq $row) { return }
    if ($script:Editing) { Commit-Edit }
    $id = [string]$row.Tag
    if ($script:AnimatingIds.ContainsKey($id)) { return }
    $tb = $row.Controls["label"]
    if ($null -eq $tb) { return }

    $script:Editing     = $true
    $script:EditRowId   = $id
    $script:EditOldText = $tb.Text
    $script:EditBox     = $tb

    # Plain background while editing (no hover highlight bar behind the text).
    $row.Hovered = $false
    $row.Invalidate($true)
    $tb.BackColor = $script:BG
    $tb.ForeColor = $script:FG

    # Flip the SAME control into editable mode — nothing about the text moves.
    $tb.EditMode = $true
    $tb.ReadOnly = $false
    $tb.TabStop  = $true
    $tb.SelectionStart = $tb.Text.Length
    $tb.SelectionLength = 0
    $tb.Focus()
}

function Commit-Edit {
    if (-not $script:Editing) { return }
    $tb = $script:EditBox
    $id = $script:EditRowId
    $old = $script:EditOldText
    $new = if ($tb) { $tb.Text.Trim() } else { "" }
    $script:Editing = $false
    $script:EditBox = $null
    if ($tb) {
        $tb.EditMode = $false
        $tb.ReadOnly = $true
        $tb.TabStop  = $false
        $tb.SelectionLength = 0
        $form.ActiveControl = $null    # drop focus so the caret disappears
    }
    if ($new -and $new -ne $old) {
        # Record for Ctrl+Z, save, then relayout (the text may have re-wrapped).
        $script:UndoStack.Push([pscustomobject]@{ Kind = 'edit'; Id = [string]$id; OldText = $old })
        Set-TodoText $id $new
        $script:LastMtime = Get-TodoFileMtime
        if ($tb) { $tb.Text = $new }
        Relayout-Rows
    } elseif ($tb) {
        $tb.Text = $old                # blank/unchanged edit -> keep original
    }
    Refresh-Hover
}

function Cancel-Edit {
    if (-not $script:Editing) { return }
    $tb = $script:EditBox
    $old = $script:EditOldText
    $script:Editing = $false
    $script:EditBox = $null
    if ($tb) {
        $tb.EditMode = $false
        $tb.ReadOnly = $true
        $tb.TabStop  = $false
        $tb.Text = $old
        $tb.SelectionLength = 0
        $form.ActiveControl = $null
    }
    Refresh-Hover
}

function Undo-LastComplete {
    # Undo the most recent change: a checked-off task (bring it back) or a text edit.
    while ($script:UndoStack.Count -gt 0) {
        $action = $script:UndoStack.Pop()
        $id = [string]$action.Id
        $item = @(Get-Todos) | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1
        if ($null -eq $item) { continue }   # gone entirely; keep popping

        if ($action.Kind -eq 'edit') {
            Set-TodoText $id $action.OldText
            $script:LastMtime = Get-TodoFileMtime
            Update-List
            Refresh-Hover
            return
        }

        # 'complete' — bring back the most recently checked-off task.
        if ([bool]$item.done) {
            Toggle-Todo $id            # un-complete it (done -> false)
            $script:LastMtime = Get-TodoFileMtime
            $script:FadeInIds[$id] = $true
            Update-List
            Refresh-Hover
            Start-RestoreSlide $id
            return
        }
        # otherwise it was already restored; keep popping
    }
}

function Update-List {
    # Suppress repainting during the rebuild so the list doesn't blink.
    $suppress = $listPanel.IsHandleCreated
    if ($suppress) { [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $false, 0) }
    $listPanel.SuspendLayout()
    try {
        Rebuild-Rows
    } finally {
        $listPanel.ResumeLayout($false)
        if ($suppress) {
            [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $true, 0)
            $listPanel.Invalidate($true)
        }
    }
}

function New-CapsulePath {
    param([int]$x, [int]$y, [int]$w, [int]$h)
    $r = [Math]::Min($w, $h) / 2.0
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($d -le 0) {
        $path.AddRectangle((New-Object System.Drawing.Rectangle($x, $y, $w, $h)))
        return $path
    }
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $path.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $path.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# Float-precision capsule so a sub-pixel-thin thumb renders crisply with AA.
function New-CapsulePathF {
    param([double]$x, [double]$y, [double]$w, [double]$h)
    $r = [Math]::Min($w, $h) / 2.0
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($d -le 0) {
        $path.AddRectangle((New-Object System.Drawing.RectangleF([single]$x, [single]$y, [single]$w, [single]$h)))
        return $path
    }
    $path.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $path.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $path.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $path.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-RoundedRectPath {
    param([int]$x, [int]$y, [int]$w, [int]$h, [int]$r)
    $d = $r * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($d -le 0) {
        $path.AddRectangle((New-Object System.Drawing.Rectangle($x, $y, $w, $h)))
        return $path
    }
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $path.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $path.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Enable-DwmRounding {
    # Win11 native rounded corners — smoothly anti-aliased by the OS (like Cursor).
    try {
        $pref = 2  # DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2
        [void][Native.Win]::DwmSetWindowAttribute($form.Handle, 33, [ref]$pref, 4)
    } catch { }
}

function New-PartialRoundedPath {
    param([int]$w, [int]$h, [int]$r, [bool]$roundTop, [bool]$roundBottom)
    $d = $r * 2
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($roundTop) {
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc(($w - $d), 0, $d, $d, 270, 90)
    } else {
        $p.AddLine(0, 0, $w, 0)
    }
    if ($roundBottom) {
        $p.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
        $p.AddArc(0, ($h - $d), $d, $d, 90, 90)
    } else {
        $p.AddLine($w, $h, 0, $h)
    }
    $p.CloseFigure()
    return $p
}

function Update-ChildRegions {
    # Clip the top/bottom bars to the window's rounded corners so the form's
    # gray border shows through at the corners instead of being covered.
    $r = $script:CornerRadius
    $ht = New-PartialRoundedPath $header.Width $header.Height $r $true $false
    $header.Region = New-Object System.Drawing.Region($ht)
    $ht.Dispose()
    $ib = New-PartialRoundedPath $inputPanel.Width $inputPanel.Height $r $false $true
    $inputPanel.Region = New-Object System.Drawing.Region($ib)
    $ib.Dispose()
}

function Get-MaxScroll {
    $m = $script:ContentHeight - $listPanel.ClientSize.Height
    if ($m -lt 0) { return 0 } else { return $m }
}

function Apply-Scroll {
    # Reposition the rows: each move BLITS the row's already-rendered pixels to
    # the new spot and auto-invalidates only the thin uncovered strip. We DON'T
    # force-repaint the rows (no Invalidate($true)) — that was re-rasterizing every
    # task's native text each frame and capping the scroll at ~60fps. A single
    # Update() then flushes the exposed background strip so nothing smears or
    # leaves trails. Result: text glides at the display's refresh rate, clean.
    foreach ($r in $script:RowControls) {
        $r.Top = $r.LayoutY - $script:ScrollOffset
    }
    $scrollBar.Invalidate()   # repaint the thumb so it tracks the cursor while dragging the bar
    if ($listPanel.IsHandleCreated) { $listPanel.Update() }
}

function Set-ScrollOffset {
    param([int]$v)
    $max = Get-MaxScroll
    if ($v -lt 0) { $v = 0 }
    if ($v -gt $max) { $v = $max }
    if ($v -ne $script:ScrollOffset) {
        $script:ScrollOffset = $v
        Apply-Scroll
    }
    # Keep the thumb's position source current so a later resize eases from here.
    if ($script:LenActive) { $script:LenTargetOffset = [double]$script:ScrollOffset }
    else { $script:DisplayOffset = [double]$script:ScrollOffset }
}

function Set-ScrollFraction {
    param([double]$f)
    if ($f -lt 0) { $f = 0 }
    if ($f -gt 1) { $f = 1 }
    Set-ScrollOffset ([int]($f * (Get-MaxScroll)))
}

function Scroll-By {
    param([int]$dy)
    Set-ScrollOffset ($script:ScrollOffset + $dy)
}

# Smooth wheel scrolling: accumulate a target and ease toward it in the same
# high-frame-rate render loop used for dragging (silky on high-refresh displays).
function Smooth-ScrollBy {
    param([int]$dy)
    $max = Get-MaxScroll
    if (-not $script:ScrollActive) { $script:ScrollPos = [double]$script:ScrollOffset; $script:ScrollTarget = [double]$script:ScrollOffset }
    $t = $script:ScrollTarget + $dy
    if ($t -lt 0) { $t = 0 }
    if ($t -gt $max) { $t = $max }
    $script:ScrollTarget = $t
    if (-not $script:ScrollActive) {
        $script:ScrollActive = $true
        $script:ScrollClock.Restart()
        if (-not $dragTimer.Enabled) { $dragTimer.Start() }
    }
}

function Scroll-Frame {
    if (-not $script:ScrollActive) { return $false }
    # Cap repaints to 240 fps; the glide is dt-based so a skipped frame just
    # folds its time into the next one (motion stays correct, CPU stays low).
    if ($script:ScrollFrameClock.Elapsed.TotalSeconds -lt $script:ScrollMinFrame) { return $false }
    $script:ScrollFrameClock.Restart()

    # Keep the target valid if the list changed underneath us.
    $max = Get-MaxScroll
    if ($script:ScrollTarget -gt $max) { $script:ScrollTarget = $max }
    if ($script:ScrollTarget -lt 0)    { $script:ScrollTarget = 0 }

    $dt = $script:ScrollClock.Elapsed.TotalSeconds
    $script:ScrollClock.Restart()
    if ($dt -le 0)    { $dt = 0.001 }
    if ($dt -gt 0.05) { $dt = 0.05 }
    $ease = 1.0 - [Math]::Exp(-$dt / $script:Anim.ScrollTau)

    $diff = $script:ScrollTarget - $script:ScrollPos
    if ([Math]::Abs($diff) -lt 0.5) {
        $script:ScrollPos = $script:ScrollTarget
        $script:ScrollActive = $false
    } else {
        $step = $diff * $ease
        if ([Math]::Abs($step) -lt 1) { $step = [Math]::Sign($diff) }
        $script:ScrollPos = $script:ScrollPos + $step
    }

    $newOffset = [int][Math]::Round($script:ScrollPos)
    $changed = $false
    if ($newOffset -ne $script:ScrollOffset) {
        $script:ScrollOffset = $newOffset
        Apply-Scroll
        $scrollBar.Invalidate()
        $changed = $true
    }
    if ($script:LenActive) { $script:LenTargetOffset = [double]$script:ScrollOffset }
    else { $script:DisplayOffset = [double]$script:ScrollOffset }
    return $changed
}

# Animates the thumb's length toward the real content height. Time-based
# ease-out (1-(1-t)^3): the length change moves fast up front, then eases off —
# ~60% of the change is done in the first quarter of the duration, the rest
# glides in gently. Runs on the shared high-frame-rate loop (720Hz-friendly).
function Len-Frame {
    if (-not $script:LenActive) { return $false }
    $dur = $script:Anim.LenDur
    $t = if ($dur -gt 0) { $script:LenClock.Elapsed.TotalSeconds / $dur } else { 1 }
    if ($t -ge 1) {
        $script:DisplayContent = $script:LenTarget
        $script:DisplayOffset  = $script:LenTargetOffset
        $script:LenActive = $false
        $scrollBar.Invalidate()
        return $true
    }
    $eased = 1.0 - [Math]::Pow(1.0 - $t, 3)
    $script:DisplayContent = $script:LenStart + ($script:LenTarget - $script:LenStart) * $eased
    $script:DisplayOffset  = $script:LenStartOffset + ($script:LenTargetOffset - $script:LenStartOffset) * $eased
    $scrollBar.Invalidate()
    return $true
}

# ---- Drag-to-reorder --------------------------------------------------------

function Begin-Drag {
    param($row)
    if ($null -eq $row) { return }
    $script:DragActive = $true
    $script:DragSettling = $false
    $script:DragRow = $row
    $lp = $listPanel.PointToClient([System.Windows.Forms.Cursor]::Position)
    $script:DragOffsetY = $lp.Y - $row.Top
    $script:DragDir = 1
    $script:DragLastCenter = $row.Top + $row.Height / 2.0
    $script:DragClock.Restart()
    $script:DragOrder = @($script:RowControls)
    foreach ($r in $script:RowControls) {
        $r | Add-Member -NotePropertyName DragTarget -NotePropertyValue $r.Top -Force
        if ($r -ne $row) { $r.Hovered = $false }
    }
    $row.Hovered = $true
    $row.BringToFront()
    $row.Invalidate($true)
    $dragTimer.Start()
}

function Update-DragTargets {
    if (-not $script:DragActive) { return }
    $dr = $script:DragRow
    $lp = $listPanel.PointToClient([System.Windows.Forms.Cursor]::Position)
    $dragTop = $lp.Y - $script:DragOffsetY
    $minTop = -4
    $maxTop = [Math]::Max($minTop, $listPanel.ClientSize.Height - $dr.Height + 4)
    if ($dragTop -lt $minTop) { $dragTop = $minTop }
    if ($dragTop -gt $maxTop) { $dragTop = $maxTop }
    $script:DragDesiredTop = $dragTop
    $dragCenter = $dragTop + $dr.Height / 2.0

    # Track drag direction (with a small epsilon) so the "leeway" is applied
    # toward the way you're moving — the gap opens before you reach the
    # neighbour's midpoint, and reversing flips the bias (built-in hysteresis).
    if ([Math]::Abs($dragCenter - $script:DragLastCenter) -gt 0.5) {
        $script:DragDir = if ($dragCenter -gt $script:DragLastCenter) { 1 } else { -1 }
        $script:DragLastCenter = $dragCenter
    }
    $leeway = [Math]::Max(10.0, $dr.Height * 0.30)
    $probe = $dragCenter + ($script:DragDir * $leeway)

    $others = @($script:DragOrder | Where-Object { $_ -ne $dr })
    $startY = $script:ListTop - $script:ScrollOffset

    # Determine insertion index from the probe point vs. the (gap-free) stack.
    $y = $startY
    $k = 0
    for ($i = 0; $i -lt $others.Count; $i++) {
        $center = $y + $others[$i].Height / 2.0
        if ($center -lt $probe) { $k = $i + 1 }
        $y += $others[$i].Height + $script:RowGap
    }
    $script:DragIndex = $k

    # Assign target tops: rows at/after k slide down to open a gap.
    $dragShift = $dr.Height + $script:RowGap
    $y = $startY
    for ($i = 0; $i -lt $others.Count; $i++) {
        if ($i -eq $k) { $y += $dragShift }
        $others[$i].DragTarget = $y
        $y += $others[$i].Height + $script:RowGap
    }
}

function End-Drag {
    if (-not $script:DragActive) { return }
    $dr = $script:DragRow
    Update-DragTargets
    $k = $script:DragIndex
    $others = @($script:DragOrder | Where-Object { $_ -ne $dr })

    $newOrder = @()
    for ($i = 0; $i -le $others.Count; $i++) {
        if ($i -eq $k) { $newOrder += $dr }
        if ($i -lt $others.Count) { $newOrder += $others[$i] }
    }

    # Recompute layout for the new order and set animation targets.
    $y = $script:ListTop
    foreach ($r in $newOrder) {
        $r.LayoutY = $y
        $r.DragTarget = $y - $script:ScrollOffset
        $y += $r.Height + $script:RowGap
    }
    $script:RowControls = $newOrder
    $script:ContentHeight = ($y - $script:RowGap) + $script:ListBottom

    $script:DragActive = $false
    $script:DragSettling = $true
    $script:DragClock.Restart()
    if (-not $dragTimer.Enabled) { $dragTimer.Start() }
}

function Finalize-DragCommit {
    $script:DragSettling = $false
    foreach ($r in $script:RowControls) { $r.Top = $r.LayoutY - $script:ScrollOffset }

    $ids = @($script:RowControls | ForEach-Object { [string]$_.Tag })
    Set-TodoOrder $ids
    $script:LastMtime = Get-TodoFileMtime

    $dr = $script:DragRow
    if ($dr) {
        $pos = $dr.PointToClient([System.Windows.Forms.Cursor]::Position)
        $on = $dr.ClientRectangle.Contains($pos)
        $dr.Hovered = $on
        $lbl = $dr.Controls["label"]
        if ($lbl) {
            $lbl.ForeColor = if ($on) { $script:HoverText } else { $script:FG }
            $lbl.BackColor = if ($on) { $script:BGHover } else { $script:BG }
        }
        $dr.Invalidate($true)
    }
    $script:DragRow = $null
    Position-ScrollBar
    Update-ScrollVisibility
}

# One frame of drag motion. Called from mouse-move (at the mouse's polling
# rate, for latency-free tracking) and from a fallback timer (for easing while
# the cursor is still and for the drop settle). Easing is time-based so the
# animation looks identical regardless of how often this runs.
function Drag-Frame {
    if (-not $script:DragActive -and -not $script:DragSettling) { return $false }
    if ($script:DragActive) { Update-DragTargets }

    $dt = $script:DragClock.Elapsed.TotalSeconds
    $script:DragClock.Restart()
    if ($dt -le 0)   { $dt = 0.001 }
    if ($dt -gt 0.05) { $dt = 0.05 }
    $tau = $script:Anim.DragTau
    $ease = 1.0 - [Math]::Exp(-$dt / $tau)

    $dr = $script:DragRow
    $suppress = $listPanel.IsHandleCreated
    if ($suppress) { [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $false, 0) }

    $settled = $true
    $changed = $false
    if ($script:DragActive -and $dr) {
        $ny = [int]$script:DragDesiredTop
        if ($dr.Top -ne $ny) { $dr.Top = $ny; $changed = $true }
    }
    foreach ($r in $script:RowControls) {
        if ($script:DragActive -and $r -eq $dr) { continue }
        $cur = $r.Top
        $tgt = [int]$r.DragTarget
        $diff = $tgt - $cur
        if ([Math]::Abs($diff) -le 1) { if ($r.Top -ne $tgt) { $r.Top = $tgt; $changed = $true }; continue }
        $nv = $cur + $diff * $ease
        if ([Math]::Abs($nv - $cur) -lt 1) { $nv = $cur + [Math]::Sign($diff) }
        $r.Top = [int][Math]::Round($nv)
        $changed = $true
        if ([Math]::Abs($tgt - $r.Top) -gt 1) { $settled = $false }
    }

    if ($suppress) {
        [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $true, 0)
        if ($changed) {
            $listPanel.Invalidate($true)
            $listPanel.Update()
        }
    }

    if ($script:DragSettling -and $settled) {
        $dragTimer.Stop()
        Finalize-DragCommit
    }
    return $changed
}

# Eases every row toward its DragTarget (used for the drop settle AND for the
# "slide down" when a task is restored). Runs inside the same high-frame-rate
# loop as dragging, so it's smooth on high-refresh displays.
function Slide-Frame {
    if (-not $script:SlideActive) { return $false }
    $dt = $script:SlideClock.Elapsed.TotalSeconds
    $script:SlideClock.Restart()
    if ($dt -le 0)   { $dt = 0.001 }
    if ($dt -gt 0.05) { $dt = 0.05 }
    $ease = 1.0 - [Math]::Exp(-$dt / $script:Anim.SlideTau)

    $suppress = $listPanel.IsHandleCreated
    if ($suppress) { [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $false, 0) }

    $settled = $true
    $changed = $false
    foreach ($r in $script:RowControls) {
        $cur = $r.Top
        $tgt = [int]$r.DragTarget
        $diff = $tgt - $cur
        if ([Math]::Abs($diff) -le 1) { if ($r.Top -ne $tgt) { $r.Top = $tgt; $changed = $true }; continue }
        $nv = $cur + $diff * $ease
        if ([Math]::Abs($nv - $cur) -lt 1) { $nv = $cur + [Math]::Sign($diff) }
        $r.Top = [int][Math]::Round($nv)
        $changed = $true
        if ([Math]::Abs($tgt - $r.Top) -gt 1) { $settled = $false }
    }

    if ($suppress) {
        [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $true, 0)
        if ($changed) { $listPanel.Invalidate($true); $listPanel.Update() }
    }

    if ($settled) { $script:SlideActive = $false }
    return $changed
}

# Dispatches a single animation frame to whichever motions are in progress.
function Animate-Frame {
    $changed = $false
    if ($script:DragActive -or $script:DragSettling) {
        if (Drag-Frame) { $changed = $true }
    } else {
        if ($script:SlideActive)  { if (Slide-Frame)  { $changed = $true } }
        if ($script:ScrollActive) { if (Scroll-Frame) { $changed = $true } }
    }
    if ($script:Fades.Count -gt 0) { if (Fade-Frame) { $changed = $true } }
    if ($script:LenActive) { if (Len-Frame) { $changed = $true } }
    return $changed
}

# After a task is restored, make the rows below it slide down into place: they
# start shifted up (their pre-restore positions) and ease to their new slots.
function Start-RestoreSlide {
    param($id)
    if ($script:RowControls.Count -eq 0) { return }
    $idx = -1
    for ($i = 0; $i -lt $script:RowControls.Count; $i++) {
        if ([string]$script:RowControls[$i].Tag -eq [string]$id) { $idx = $i; break }
    }
    if ($idx -lt 0) { return }
    $shift = $script:RowControls[$idx].Height + $script:RowGap

    $suppress = $listPanel.IsHandleCreated
    if ($suppress) { [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $false, 0) }
    for ($i = 0; $i -lt $script:RowControls.Count; $i++) {
        $r = $script:RowControls[$i]
        $r | Add-Member -NotePropertyName DragTarget -NotePropertyValue $r.Top -Force
        if ($i -gt $idx) { $r.Top = $r.Top - $shift }   # start at old spot, slide down
    }
    if ($suppress) {
        [void][Native.Win]::SendMessage($listPanel.Handle, 0x000B, $true, 0)
        $listPanel.Invalidate($true)
    }

    if ($idx -lt $script:RowControls.Count - 1) {
        $script:SlideActive = $true
        $script:SlideClock.Restart()
        if (-not $dragTimer.Enabled) { $dragTimer.Start() }
    }
}

function Position-ScrollBar {
    $scrollBar.Height = $listPanel.ClientSize.Height
    $scrollBar.Location = New-Object System.Drawing.Point(
        ($listPanel.ClientSize.Width - $script:ScrollWidth - $script:ScrollRightPad), 0)
    $scrollBar.BringToFront()
    $scrollBar.Invalidate()
}

function Update-ScrollVisibility {
    # Show the bar only when the list overflows; fade otherwise.
    $need = (Get-MaxScroll) -gt 0
    $script:ScrollTargetAlpha = if ($need) { $script:ScrollMaxAlpha } else { 0 }

    # Snap the thumb size on first layout; animate it thereafter.
    if (-not $script:ScrollReady) {
        $script:DisplayContent = $script:ContentHeight
        $script:DisplayOffset  = [double]$script:ScrollOffset
        $script:ScrollReady = $true
    }

    # Opacity fade stays on the light 16ms timer.
    if ($script:ScrollAlpha -ne $script:ScrollTargetAlpha) { $fadeTimer.Start() }

    # Thumb length change is animated on the high-frame-rate loop (Len-Frame).
    # Ease the content height (size) AND the offset (position) together so the
    # thumb stays pinned to the end you're at while it resizes.
    if ([Math]::Abs($script:DisplayContent - $script:ContentHeight) -gt 1) {
        $script:LenStart        = [double]$script:DisplayContent
        $script:LenTarget       = [double]$script:ContentHeight
        $script:LenStartOffset  = [double]$script:DisplayOffset   # where the thumb sits right now
        $script:LenTargetOffset = [double]$script:ScrollOffset    # the new (already clamped) offset
        $script:LenClock.Restart()
        $script:LenActive = $true
        if (-not $dragTimer.Enabled) { $dragTimer.Start() }   # fallback ticker; Idle drives it at refresh rate
    } elseif (-not $script:LenActive) {
        $script:DisplayContent = $script:ContentHeight
        $script:DisplayOffset  = [double]$script:ScrollOffset
    }
}

function Rebuild-Rows {
    foreach ($ctrl in $script:RowControls) {
        $listPanel.Controls.Remove($ctrl)
        $ctrl.Dispose()
    }
    $script:RowControls = @()

    $items = @(Get-ActiveTodos)
    if ($items.Count -eq 0) {
        $emptyLabel.Visible = $true
        $script:ContentHeight = 0
        $script:ScrollOffset = 0
        Position-ScrollBar
        Update-ScrollVisibility
        return
    }
    $emptyLabel.Visible = $false

    $rowWidth = [Math]::Max(160, $listPanel.ClientSize.Width - $script:ListLeft - $script:RightGutter)
    $textWidth = [Math]::Max(120, $rowWidth - $script:BulletWidth)
    $ly = $script:ListTop
    foreach ($item in $items) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Name = "row"
        $row.Width = $rowWidth
        $row.Location = New-Object System.Drawing.Point($script:ListLeft, ($ly - $script:ScrollOffset))
        $row.BackColor = $script:BG
        $row.Cursor = [System.Windows.Forms.Cursors]::Hand
        $row.Tag = $item.id
        $row | Add-Member -NotePropertyName Hovered -NotePropertyValue $false -Force
        Set-DoubleBuffered $row
        $row.Add_Paint($script:RowPaint)

        $maxSize = New-Object System.Drawing.Size($textWidth, 1000)
        $wb = [System.Windows.Forms.TextFormatFlags]::WordBreak
        $baseMeasure = [System.Windows.Forms.TextRenderer]::MeasureText($item.text, $script:MonoFont, $maxSize, $wb)

        $rowHeight = [Math]::Max(32, $baseMeasure.Height + 12)
        $row.Height = $rowHeight

        $restX = $script:BulletWidth
        $baseY = [int](($rowHeight - $baseMeasure.Height) / 2)

        $bullet = New-Object System.Windows.Forms.Label
        $bullet.Name = "bullet"
        $bullet.Text = $script:Bullet
        $bullet.Font = New-Object System.Drawing.Font("Segoe UI", 12)
        $bullet.ForeColor = $script:FGDim
        $bullet.BackColor = [System.Drawing.Color]::Transparent
        $bullet.AutoSize = $false
        $bullet.Width = $script:BulletWidth
        $bullet.Height = $rowHeight
        $bullet.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $bullet.Location = New-Object System.Drawing.Point(0, 0)
        $bullet.Cursor = [System.Windows.Forms.Cursors]::Hand
        $bullet.Tag = $item.id

        # The text lives in a read-only TaskTextBox (acts like a label until you
        # edit it). Same control for view + edit => editing changes nothing visually.
        $label = New-Object TaskTextBox
        $label.Name = "label"
        $label.Multiline = $true
        $label.WordWrap = $true
        $label.ReadOnly = $true
        $label.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $label.Font = $script:MonoFont
        $label.ForeColor = $script:FG
        $label.BackColor = $script:BG
        $label.TabStop = $false
        $label.Cursor = [System.Windows.Forms.Cursors]::Hand
        $label.Text = $item.text
        $label.Location = New-Object System.Drawing.Point($restX, ($baseY - 1))
        $label.Size = New-Object System.Drawing.Size($textWidth, ($baseMeasure.Height + 2))
        $label.Tag = $item.id
        $label | Add-Member -NotePropertyName WrapWidth -NotePropertyValue $textWidth -Force

        $onDown = {
            param($sender, $e)
            $r = Get-RowFromSender $sender
            if ($null -eq $r) { return }
            if ($script:AnimatingIds.ContainsKey([string]$r.Tag)) { return }
            $id = [string]$r.Tag

            # Right-click a task to edit it. Right-clicking the task you're already
            # editing exits edit mode (and re-checks hover, via Commit-Edit).
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
                if ($script:Editing) {
                    $wasThis = ($id -eq [string]$script:EditRowId)
                    Commit-Edit
                    if ($wasThis) { return }
                }
                $fresh = Find-RowById $id
                if ($fresh) { Begin-Edit $fresh }
                return
            }
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

            # Left-click while editing: commit first, but keep going so a click-and-
            # hold on another task starts a drag in this same gesture (no 2nd click).
            # Suppress the mouse-up complete so we don't accidentally check it off.
            if ($script:Editing) {
                Commit-Edit
                $script:SuppressNextComplete = $true
            }
            $script:DragPending = $true
            $script:DragCandidate = $r
            $script:DragStartScreen = [System.Windows.Forms.Cursor]::Position
        }
        $onMove = {
            param($sender, $e)
            if ($script:DragActive) {
                # Render a frame right now, at the mouse's polling rate — this is
                # what makes the drag track smoothly on high-refresh displays
                # (far past the ~100Hz ceiling of a WinForms timer).
                Drag-Frame
                return
            }
            if (-not $script:DragPending) { return }
            $now = [System.Windows.Forms.Cursor]::Position
            $dx = [Math]::Abs($now.X - $script:DragStartScreen.X)
            $dy = [Math]::Abs($now.Y - $script:DragStartScreen.Y)
            if ($dx -ge $script:DragThreshold -or $dy -ge $script:DragThreshold) {
                Begin-Drag $script:DragCandidate
            }
        }
        $onUp = {
            param($sender, $e)
            if ($script:DragActive) {
                End-Drag
                $script:DragPending = $false
                $script:SuppressNextComplete = $false
                return
            }
            if ($script:DragPending) {
                $script:DragPending = $false
                # This click only exited edit mode — don't also check the task off.
                if ($script:SuppressNextComplete) { $script:SuppressNextComplete = $false; return }
                $r = $script:DragCandidate
                if ($r -and -not $script:AnimatingIds.ContainsKey([string]$r.Tag)) {
                    $b = $r.Controls["bullet"]
                    $l = $r.Controls["label"]
                    Start-FadeOut $r $b $l $r.Tag
                }
            }
        }

        $hoverIn = {
            param($sender, $e)
            Enter-Row (Get-RowFromSender $sender)
        }
        $hoverOut = {
            param($sender, $e)
            Leave-Row (Get-RowFromSender $sender)
        }

        foreach ($ctl in @($row, $bullet, $label)) {
            $ctl.Add_MouseDown($onDown)
            $ctl.Add_MouseMove($onMove)
            $ctl.Add_MouseUp($onUp)
            $ctl.Add_MouseEnter($hoverIn)
            $ctl.Add_MouseLeave($hoverOut)
        }
        # Edit-mode keys/blur (only ever fire once the text box is editable).
        $label.Add_KeyDown($script:EditKeyDown)
        $label.Add_LostFocus($script:EditLostFocus)

        $row | Add-Member -NotePropertyName LayoutY -NotePropertyValue $ly -Force
        $row.Controls.AddRange(@($bullet, $label))
        $listPanel.Controls.Add($row)
        # Zero the edit control's internal margins so its word-wrap width equals
        # the width we measured with (keeps text from wrapping/clipping oddly).
        # EM_SETMARGINS = 0xD3, EC_LEFTMARGIN | EC_RIGHTMARGIN = 3
        [void][Native.Win]::SendMessageInt($label.Handle, 0xD3, 3, 0)
        $script:RowControls += $row

        if ($script:FadeInIds.ContainsKey([string]$item.id)) {
            $script:FadeInIds.Remove([string]$item.id)
            Start-FadeIn $row $bullet $label $item.id
        }

        $ly += $rowHeight + $script:RowGap
    }

    $script:ContentHeight = ($ly - $script:RowGap) + $script:ListBottom

    # Keep the current scroll position valid after the list changes.
    $max = Get-MaxScroll
    if ($script:ScrollOffset -gt $max) { $script:ScrollOffset = $max }
    if ($script:ScrollOffset -lt 0) { $script:ScrollOffset = 0 }
    Apply-Scroll
    Position-ScrollBar
    Update-ScrollVisibility
}

# Recompute row heights/positions for the CURRENT controls (no dispose/rebuild).
# Used after an in-place text edit that may have changed how a line wraps.
function Relayout-Rows {
    if ($script:RowControls.Count -eq 0) { return }
    $rowWidth = [Math]::Max(160, $listPanel.ClientSize.Width - $script:ListLeft - $script:RightGutter)
    $textWidth = [Math]::Max(120, $rowWidth - $script:BulletWidth)
    $maxSize = New-Object System.Drawing.Size($textWidth, 1000)
    $wb = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $ly = $script:ListTop
    foreach ($row in $script:RowControls) {
        $lbl = $row.Controls["label"]
        $txt = if ($lbl) { $lbl.Text } else { "" }
        $m = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $script:MonoFont, $maxSize, $wb)
        $rh = [Math]::Max(32, $m.Height + 12)
        $row.Width = $rowWidth
        $row.Height = $rh
        $row | Add-Member -NotePropertyName LayoutY -NotePropertyValue $ly -Force
        $row.Location = New-Object System.Drawing.Point($script:ListLeft, ($ly - $script:ScrollOffset))
        $baseY = [int](($rh - $m.Height) / 2)
        $bl = $row.Controls["bullet"]
        if ($bl) { $bl.Height = $rh }
        if ($lbl) {
            $lbl.Location = New-Object System.Drawing.Point($script:BulletWidth, ($baseY - 1))
            $lbl.Size = New-Object System.Drawing.Size($textWidth, ($m.Height + 2))
        }
        $row.Invalidate($true)
        $ly += $rh + $script:RowGap
    }
    $script:ContentHeight = ($ly - $script:RowGap) + $script:ListBottom
    $max = Get-MaxScroll
    if ($script:ScrollOffset -gt $max) { $script:ScrollOffset = $max }
    if ($script:ScrollOffset -lt 0) { $script:ScrollOffset = 0 }
    Apply-Scroll
    Position-ScrollBar
    Update-ScrollVisibility
}

function Poll-Store {
    if ($script:DragActive -or $script:DragSettling -or $script:Editing) { return }
    $mtime = Get-TodoFileMtime
    if ($mtime -ne $script:LastMtime) {
        $script:LastMtime = $mtime
        Update-List
    }
}

# Clicking/focusing the box clears ONLY the default placeholder, so the caret
# starts at the left. Real text you typed is kept (HasPlaceholder is false for it).
$inputBox.Add_GotFocus({ Clear-Placeholder })
$inputBox.Add_LostFocus({ Restore-Placeholder })
# Also clear the hint the moment the user types, as a safety net.
$inputBox.Add_KeyPress({
    param($sender, $e)
    if ($script:HasPlaceholder) { Clear-Placeholder }
})
$inputBox.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq "Return") {
        Add-TaskFromInput
        $e.SuppressKeyPress = $true
    }
})
$addBtn.Add_Click({ Add-TaskFromInput })

# Ctrl+Z anywhere in the app restores the last checked-off task (fades back in).
$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    if ($script:Editing) { return }
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Z) {
        Undo-LastComplete
        $e.SuppressKeyPress = $true
        $e.Handled = $true
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800
$timer.Add_Tick({ Poll-Store })
$timer.Start()

# Fades the scrollbar in quickly when needed and out when everything fits.
$fadeTimer = New-Object System.Windows.Forms.Timer
$fadeTimer.Interval = 16
$fadeTimer.Add_Tick({
    $moving = $false

    # Opacity fade (quick in, gentler out).
    $cur = $script:ScrollAlpha
    $target = $script:ScrollTargetAlpha
    if ($cur -ne $target) {
        if ($cur -lt $target) { $cur = [Math]::Min($target, $cur + 90) }
        else { $cur = [Math]::Max($target, $cur - 45) }
        $script:ScrollAlpha = $cur
        $moving = $true
    }

    $scrollBar.Invalidate()
    if (-not $moving) { $fadeTimer.Stop() }
})

# Drives the drag-to-reorder motion: the picked-up row follows the cursor while
# the others ease into their new slots. Painting is batched to avoid flicker.
$dragTimer = New-Object System.Windows.Forms.Timer
$dragTimer.Interval = 10   # OS clamps WinForms timers to ~10ms; this is only the
$dragTimer.Add_Tick({      # fallback for cursor-idle easing and the drop settle.
    if (-not $script:DragActive -and -not $script:DragSettling -and -not $script:SlideActive -and -not $script:ScrollActive -and -not $script:LenActive -and $script:Fades.Count -eq 0) { $dragTimer.Stop(); return }
    Animate-Frame
})

function Position-DateLabel {
    # Position the close button at the top-right, then place the date to its left.
    # Measure with TextRenderer for a reliable width (PreferredWidth/Width can be 0
    # before the form is realized), and vertically center within the header.
    $closeX = $header.ClientSize.Width - $closeBtn.Width - 8
    if ($closeX -lt 0) { $closeX = 0 }
    $closeBtn.Location = New-Object System.Drawing.Point($closeX, 8)

    $size = [System.Windows.Forms.TextRenderer]::MeasureText($dateLabel.Text, $script:DateFont)
    $dateLabel.AutoSize = $false
    $dateLabel.Size = New-Object System.Drawing.Size($size.Width, $size.Height)
    $x = $closeBtn.Left - $dateLabel.Width - 10
    if ($x -lt 0) { $x = 0 }
    $y = [int](($header.ClientSize.Height - $dateLabel.Height) / 2)
    if ($y -lt 0) { $y = 0 }
    $dateLabel.Location = New-Object System.Drawing.Point($x, $y)
    $closeBtn.Invalidate()
}

# Rounded gray border drawn around the window edge (matches the divider color).
$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundedRectPath 0 0 ($form.Width - 1) ($form.Height - 1) $script:CornerRadius
    $pen = New-Object System.Drawing.Pen $script:Border, 1
    $pen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($pen, $path)
    $pen.Dispose()
    $path.Dispose()
})

$form.Add_Shown({
    Enable-DwmRounding; Update-ChildRegions; Position-DateLabel; Position-ScrollBar; Update-List
    # Re-assert the taskbar icon now that the window (and its taskbar button)
    # exist, so it can't fall back to the PowerShell host icon. WM_SETICON=0x80.
    if ($script:AppIconBig) {
        try {
            [void][Native.Win]::SendMessagePtr($form.Handle, 0x80, [IntPtr]1, $script:AppIconBig.Handle)   # ICON_BIG
            [void][Native.Win]::SendMessagePtr($form.Handle, 0x80, [IntPtr]0, $script:AppIconSmall.Handle) # ICON_SMALL
        } catch { }
    }
})
$form.Add_SizeChanged({ Update-ChildRegions })
$header.Add_Resize({ Position-DateLabel })

# Mouse-wheel scrolling for the list, routed via a message filter so it works
# whether or not the list has keyboard focus.
$wheelFilter = New-Object WheelFilter
$wheelFilter.IsOverList = [Func[System.Drawing.Point, bool]]{
    param($p)
    $lp = $listPanel.PointToClient($p)
    return $listPanel.ClientRectangle.Contains($lp)
}
$wheelFilter.OnWheel = [Action[int]]{
    param($delta)
    if ($script:DragActive -or $script:DragSettling) { return }
    $step = 60
    if ($delta -lt 0) { Smooth-ScrollBy $step } else { Smooth-ScrollBy (-$step) }
}
[System.Windows.Forms.Application]::AddMessageFilter($wheelFilter)

# High-frame-rate render loop for dragging/settling. Application.Idle fires
# whenever the message queue drains; we then render frames back-to-back (limited
# only by paint speed, not the ~100Hz WinForms timer clamp) and bail the instant
# real input is waiting. This makes the reshuffle and drop-settle silky on
# high-refresh displays. When active but nothing is moving we stop to save CPU.
$onIdle = {
    param($sender, $e)
    if (-not ($script:DragActive -or $script:DragSettling -or $script:SlideActive -or $script:ScrollActive -or $script:LenActive -or $script:Fades.Count -gt 0)) { return }
    while (($script:DragActive -or $script:DragSettling -or $script:SlideActive -or $script:ScrollActive -or $script:LenActive -or $script:Fades.Count -gt 0) -and -not [NativeMsg]::AnyMessage()) {
        $changed = Animate-Frame
        # When momentum scroll is the only motion and it's between its capped
        # frames, sleep a hair so we don't burn the CPU busy-waiting. Input is
        # re-checked every iteration, so this stays responsive.
        $scrollOnly = $script:ScrollActive -and -not $script:DragActive -and -not $script:DragSettling -and -not $script:SlideActive -and -not $script:LenActive -and $script:Fades.Count -eq 0
        if ($scrollOnly -and -not $changed) { [System.Threading.Thread]::Sleep(1) }
        if (-not $script:DragSettling -and -not $script:SlideActive -and -not $script:ScrollActive -and -not $script:LenActive -and $script:Fades.Count -eq 0 -and -not $changed) { break }
    }
}
[System.Windows.Forms.Application]::add_Idle([EventHandler]$onIdle)

$script:LastMtime = Get-TodoFileMtime
Update-List

# Raise the OS timer resolution to ~1ms so the drag loop can tick smoothly
# (WinForms timers are otherwise capped near the 15.6ms system clock).
try { [void][Native.Win]::timeBeginPeriod(1) } catch { }

[void]$form.ShowDialog()

try { [void][Native.Win]::timeEndPeriod(1) } catch { }
$timer.Stop()
$timer.Dispose()
