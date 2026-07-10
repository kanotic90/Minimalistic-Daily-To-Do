param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\storage.ps1"

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  .\todo-cli.ps1 list"
    Write-Host "  .\todo-cli.ps1 add <task>"
    Write-Host "  .\todo-cli.ps1 remove <task>"
}

if (-not $Args -or $Args.Count -eq 0 -or $Args[0] -in @("-h", "--help", "help")) {
    Show-Usage
    exit 0
}

$cmd = $Args[0].ToLower()
$rest = ($Args[1..($Args.Count - 1)] -join " ").Trim()

switch ($cmd) {
    "list" {
        $items = Get-ActiveTodos
        if (-not $items -or $items.Count -eq 0) {
            Write-Host "(empty)"
        } else {
            $bullet = [char]0x2022
            foreach ($item in $items) {
                Write-Host "  $bullet $($item.text)"
            }
        }
    }
    "add" {
        if (-not $rest) {
            Write-Error "Provide task text"
            exit 1
        }
        $item = Add-Todo $rest
        Write-Host "Added: $($item.text)"
    }
    "remove" {
        if (-not $rest) {
            Write-Error "Provide task text to remove"
            exit 1
        }
        if (Remove-Todo $rest) {
            Write-Host "Removed: $rest"
        } else {
            Write-Error "Not found: $rest"
            exit 1
        }
    }
    default {
        Write-Error "Unknown command: $cmd"
        Show-Usage
        exit 1
    }
}
