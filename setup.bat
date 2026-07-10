@echo off
setlocal
cd /d "%~dp0"

echo Installing Daily To-Do startup shortcut...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_startup.ps1"
if errorlevel 1 (
    echo Startup install failed.
    pause
    exit /b 1
)

echo.
echo Launching Daily To-Do...
call "%~dp0run.bat"

echo.
echo Done. The app will open automatically when you sign in.
pause
