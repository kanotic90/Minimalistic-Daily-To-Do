# Repair / reinstall Daily To-Do (v1.1.0)
# - Removes every old copy: shortcuts, Run key, uninstall registry, program folder.
# - Keeps your data (%LOCALAPPDATA%\DailyTodo\todos.json).
# - Reinstalls the newest app files from this folder.
# - Uses a hidden VBScript launcher via wscript.exe (a trusted system binary) so
#   antivirus doesn't quarantine a compiled .exe launcher.
# No admin required. Run:  right-click -> Run with PowerShell   (or use Repair.bat)

$ErrorActionPreference = 'Stop'
$Src         = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallRoot = Join-Path $env:LOCALAPPDATA "DailyTodo"
$AppDir      = Join-Path $InstallRoot "app"
$Version     = "1.1.0"

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

Say "Daily To-Do repair / reinstall (v$Version)" 'Cyan'
Say "  source:  $Src"
Say "  install: $AppDir"
Say ""

# 1) Stop any running instance so files aren't locked -------------------------
Say "Stopping running instances..."
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='DailyTodo.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DailyTodo*' -or $_.CommandLine -like '*launch.vbs*' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

# 2) Remove old shortcuts (per-user AND common locations) ---------------------
Say "Removing old shortcuts..."
$lnkNames = @("Daily To-Do.lnk", "DailyTodo.lnk")
$lnkDirs  = @(
    [Environment]::GetFolderPath("Programs"),
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("Startup"),
    [Environment]::GetFolderPath("CommonPrograms"),
    [Environment]::GetFolderPath("CommonDesktopDirectory"),
    [Environment]::GetFolderPath("CommonStartup")
)
foreach ($d in $lnkDirs) {
    foreach ($n in $lnkNames) {
        $p = Join-Path $d $n
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Say "  removed $p" }
    }
}

# 3) Remove old Run-key autostart entries -------------------------------------
foreach ($runKey in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
                       "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run")) {
    try {
        $props = Get-ItemProperty $runKey -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Value -match 'DailyTodo|Daily To-Do' } | ForEach-Object {
                Remove-ItemProperty -Path $runKey -Name $_.Name -Force -ErrorAction SilentlyContinue
                Say "  removed Run entry $($_.Name)"
            }
        }
    } catch {}
}

# 4) Remove old uninstall registry entries ------------------------------------
foreach ($u in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DailyTodo",
                 "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DailyTodo")) {
    if (Test-Path $u) { Remove-Item $u -Recurse -Force -ErrorAction SilentlyContinue; Say "  removed reg $u" }
}

# 5) Delete the old program folder (KEEP todos.json in the parent) ------------
if (Test-Path $AppDir) {
    Say "Removing old program folder..."
    Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 6) Fresh install of the newest files ----------------------------------------
Say "Installing newest files..."
New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
$runtime = @("DailyTodo.ps1", "storage.ps1", "Uninstall.ps1", "icon.ico")
foreach ($f in $runtime) {
    $s = Join-Path $Src $f
    if (Test-Path $s) { Copy-Item $s -Destination (Join-Path $AppDir $f) -Force; Say "  copied $f" }
    elseif ($f -ne "icon.ico") { throw "Missing required source file: $f" }
    else { Say "  (icon.ico not found in source - shortcuts will use the default icon)" 'DarkYellow' }
}

# 7) Hidden VBScript launcher (no console flash, no compiled .exe) -------------
$ps1  = Join-Path $AppDir "DailyTodo.ps1"
$vbs  = Join-Path $AppDir "launch.vbs"
$ico  = Join-Path $AppDir "icon.ico"
$vbsBody = @"
' Launches Daily To-Do with no console window.
Dim sh : Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$ps1""", 0, False
"@
Set-Content -Path $vbs -Value $vbsBody -Encoding ASCII
Say "  wrote launch.vbs"

# 8) Recreate shortcuts (Start Menu + Desktop + Startup) ----------------------
function New-Shortcut($Path, $VbsPath, $WorkDir, $IcoPath) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($Path)
    $sc.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $sc.Arguments  = '"' + $VbsPath + '"'
    $sc.WorkingDirectory = $WorkDir
    $sc.WindowStyle = 7
    $sc.Description = "Daily To-Do list"
    if (Test-Path $IcoPath) { $sc.IconLocation = $IcoPath }
    $sc.Save()
}
$programs = [Environment]::GetFolderPath("Programs")
$desktop  = [Environment]::GetFolderPath("Desktop")
$startup  = [Environment]::GetFolderPath("Startup")
New-Shortcut (Join-Path $programs "Daily To-Do.lnk") $vbs $AppDir $ico; Say "  Start Menu shortcut"
New-Shortcut (Join-Path $desktop  "Daily To-Do.lnk") $vbs $AppDir $ico; Say "  Desktop shortcut"
New-Shortcut (Join-Path $startup  "Daily To-Do.lnk") $vbs $AppDir $ico; Say "  Startup shortcut (opens on Windows start)"

# 9) Register in Apps & features ----------------------------------------------
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DailyTodo"
New-Item -Path $reg -Force | Out-Null
$uninst = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $AppDir "Uninstall.ps1") + '"'
Set-ItemProperty $reg DisplayName     "Daily To-Do"
Set-ItemProperty $reg DisplayVersion  $Version
Set-ItemProperty $reg Publisher        "Daily To-Do"
Set-ItemProperty $reg InstallLocation $AppDir
if (Test-Path $ico) { Set-ItemProperty $reg DisplayIcon $ico }
Set-ItemProperty $reg UninstallString $uninst
Set-ItemProperty $reg NoModify 1 -Type DWord
Set-ItemProperty $reg NoRepair 1 -Type DWord

# 10) Launch it ---------------------------------------------------------------
Say ""
Say "Done. Launching Daily To-Do..." 'Green'
Start-Process "$env:WINDIR\System32\wscript.exe" -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $AppDir
Say "Installed v$Version to $AppDir" 'Green'
