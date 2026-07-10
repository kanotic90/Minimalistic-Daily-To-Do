# Minimalistic Daily To-Do

A lightweight, minimalistic daily to-do application for Windows, built in PowerShell.

## Features

- Clean, minimal desktop to-do window
- Add, edit, remove, reorder, and complete tasks
- Data stored locally at `%LOCALAPPDATA%\DailyTodo\todos.json`
- Optional launch-on-startup integration
- Command-line interface for quick task management

## Usage

### Desktop app

Run the app:

```powershell
powershell -ExecutionPolicy Bypass -File DailyTodo.ps1
```

Or use `run.bat`.

### Command line

```powershell
.\todo-cli.ps1 list
.\todo-cli.ps1 add "Buy groceries"
.\todo-cli.ps1 remove "Buy groceries"
```

## Installation

Use the installer to set up the app (and optional startup shortcut):

```powershell
powershell -ExecutionPolicy Bypass -File Installer.ps1
```

To remove it:

```powershell
powershell -ExecutionPolicy Bypass -File Uninstall.ps1
```

## Project structure

| File | Purpose |
|------|---------|
| `DailyTodo.ps1` | Main desktop application |
| `storage.ps1` | Shared todo storage (JSON read/write) |
| `todo-cli.ps1` | Command-line interface |
| `Installer.ps1` / `Uninstall.ps1` | Install / uninstall scripts |
| `install_startup.ps1` | Launch-on-startup setup |
| `build-installer.ps1` | Build the distributable installer |
| `sign-installer.ps1` | Optional code-signing helper |
| `make-icon.ps1` | Icon generation helper |

## Notes

Your to-do items are stored locally on your machine and are **not** included in this repository.
