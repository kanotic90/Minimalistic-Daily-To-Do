# Removes Daily To-Do: shortcuts, the Apps & features entry, and program files.
# User data (%LOCALAPPDATA%\DailyTodo\todos.json) is kept.

$AppDir = Join-Path (Join-Path $env:LOCALAPPDATA "DailyTodo") "app"

# Stop a running instance so files aren't locked.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DailyTodo.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Remove shortcuts.
$targets = @(
    (Join-Path ([Environment]::GetFolderPath("Programs")) "Daily To-Do.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Desktop"))  "Daily To-Do.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Startup"))  "Daily To-Do.lnk")
)
foreach ($t in $targets) { if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue } }

# Remove the Apps & features registration.
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DailyTodo"
if (Test-Path $reg) { Remove-Item $reg -Recurse -Force -ErrorAction SilentlyContinue }

# Delete the program folder from a detached shell so this script isn't holding it.
if (Test-Path $AppDir) {
    $cmd = 'ping 127.0.0.1 -n 2 >nul & rmdir /s /q "' + $AppDir + '"'
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WindowStyle Hidden
}
