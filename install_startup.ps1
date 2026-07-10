# Register Daily To-Do to launch on Windows sign-in, and add a Desktop shortcut.
# Both shortcuts launch via launch.vbs (through wscript) so there is no console flash.

$AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vbs     = Join-Path $AppDir "launch.vbs"
$WScript = Join-Path $env:WINDIR "System32\wscript.exe"
$IcoPath = Join-Path $AppDir "icon.ico"

$WshShell = New-Object -ComObject WScript.Shell

function New-DailyTodoShortcut {
    param([string]$Path)
    $sc = $WshShell.CreateShortcut($Path)
    $sc.TargetPath = $WScript
    $sc.Arguments = '"' + $Vbs + '"'
    $sc.WorkingDirectory = $AppDir
    $sc.WindowStyle = 7  # Minimized — no console flash
    $sc.Description = "Daily To-Do list"
    if (Test-Path $IcoPath) {
        # Icon for the shortcut/Explorer. The taskbar icon itself comes from the
        # app's window icon (Sobble) set in DailyTodo.ps1.
        $sc.IconLocation = $IcoPath
    }
    $sc.Save()
    return $Path
}

$Startup = [Environment]::GetFolderPath("Startup")
$StartupShortcut = New-DailyTodoShortcut (Join-Path $Startup "Daily To-Do.lnk")

$Desktop = [Environment]::GetFolderPath("Desktop")
$DesktopShortcut = New-DailyTodoShortcut (Join-Path $Desktop "Daily To-Do.lnk")

Write-Host "Shortcuts created:"
Write-Host "  $StartupShortcut"
Write-Host "  $DesktopShortcut"
Write-Host ""
if (Test-Path $IcoPath) {
    Write-Host "Using icon: $IcoPath"
} else {
    Write-Host "No icon.ico yet - run make-icon.ps1 after adding icon.png to apply the Sobble icon."
}
Write-Host "Daily To-Do will open automatically when you sign in (no console window)."
