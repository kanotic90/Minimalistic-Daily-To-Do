@echo off
REM Double-click to repair/reinstall Daily To-Do (newest version).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-DailyTodo.ps1"
echo.
pause
