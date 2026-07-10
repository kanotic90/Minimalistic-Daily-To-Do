# Shared todo storage for Daily To-Do

function Get-TodoFile {
    $dir = Join-Path $env:LOCALAPPDATA "DailyTodo"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Join-Path $dir "todos.json"
}

function Get-Todos {
    $file = Get-TodoFile
    if (-not (Test-Path $file)) { return @() }
    try {
        $raw = Get-Content $file -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = ConvertFrom-Json $raw
        $flat = @()
        foreach ($entry in @($data)) {
            if ($null -eq $entry) { continue }
            $names = @($entry.PSObject.Properties.Name)
            if (($names -contains 'value') -and ($names -contains 'Count')) {
                # Repair legacy wrapper objects from older buggy saves
                foreach ($inner in @($entry.value)) {
                    if ($inner) { $flat += $inner }
                }
            } elseif ($names -contains 'text') {
                $flat += $entry
            }
        }
        return @($flat)
    } catch {
        return @()
    }
}

function Save-Todos {
    param([array]$Items)
    $file = Get-TodoFile
    # Force array output even for a single item so reads stay consistent
    $json = ConvertTo-Json -InputObject @($Items) -Depth 4
    Set-Content -Path $file -Value $json -Encoding UTF8
}

function Get-ActiveTodos {
    (Get-Todos) | Where-Object { -not $_.done }
}

function Add-Todo {
    param([string]$Text)
    $text = $Text.Trim()
    if (-not $text) { throw "Task text cannot be empty" }
    $items = @(Get-Todos)
    $item = [PSCustomObject]@{
        id      = [guid]::NewGuid().ToString("N").Substring(0, 8)
        text    = $text
        done    = $false
        created = (Get-Date -Format "o")
    }
    $items += $item
    Save-Todos $items
    return $item
}

function Remove-Todo {
    param([string]$Text)
    $needle = $Text.Trim().ToLower()
    if (-not $needle) { return $false }
    $items = @(Get-Todos)
    $idx = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        if (-not $items[$i].done -and $items[$i].text.ToLower() -eq $needle) {
            $idx = $i
            break
        }
    }
    if ($idx -lt 0) { return $false }
    $items = @($items | Where-Object { $_ -ne $items[$idx] })
    Save-Todos $items
    return $true
}

function Toggle-Todo {
    param([string]$Id)
    $items = @(Get-Todos)
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].id -eq $Id) {
            $items[$i].done = -not [bool]$items[$i].done
            break
        }
    }
    Save-Todos $items
}

function Set-TodoText {
    param([string]$Id, [string]$Text)
    $t = $Text.Trim()
    if (-not $t) { return }
    $items = @(Get-Todos)
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string]$items[$i].id -eq [string]$Id) {
            $items[$i].text = $t
            break
        }
    }
    Save-Todos $items
}

function Set-TodoOrder {
    param([string[]]$OrderedIds)
    $items = @(Get-Todos)
    $byId = @{}
    foreach ($it in $items) { $byId[[string]$it.id] = $it }
    $ordered = @()
    $used = @{}
    foreach ($id in $OrderedIds) {
        $key = [string]$id
        if ($byId.ContainsKey($key) -and -not $used.ContainsKey($key)) {
            $ordered += $byId[$key]
            $used[$key] = $true
        }
    }
    # Preserve any items not named in the new order (e.g. done items).
    foreach ($it in $items) {
        if (-not $used.ContainsKey([string]$it.id)) { $ordered += $it }
    }
    Save-Todos $ordered
}

function Get-TodoFileMtime {
    $file = Get-TodoFile
    if (-not (Test-Path $file)) { return $null }
    return (Get-Item $file).LastWriteTimeUtc.Ticks
}
