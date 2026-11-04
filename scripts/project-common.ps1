# Shared project helpers (dot-sourced by build-project, upload-rom, validate-gdb...).

function Get-DsProjectConfig {
    param([Parameter(Mandatory)] [string]$Project)
    $path = Join-Path $Project '.ds-game-dev\project.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Falta el contrato del proyecto: $path" }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Get-DsTemplatePath {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string]$Project)
    if ($Config.buildTemplate -eq 'skill-default') {
        return (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\blocksds-test')
    }
    return (Join-Path $Project $Config.buildTemplate)
}

# Files that feed the ROM: template, copy entries, project.json (+ icon).
# Used by build-project (to sync) and upload-rom (to detect stale ROMs).
function Get-DsInputFiles {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string]$Project, [Parameter(Mandatory)] [string]$Template)
    $files = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $Template) {
        foreach ($f in Get-ChildItem -LiteralPath $Template -Recurse -File -Force) { $files.Add($f) }
    }
    foreach ($item in @($Config.copy)) {
        if (-not $item) { continue }
        $src = Join-Path $Project $item.source
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Test-Path -LiteralPath $src -PathType Container) {
            foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File -Force) { $files.Add($f) }
        } else { $files.Add((Get-Item -LiteralPath $src -Force)) }
    }
    if ($Config.icon) {
        $icon = Join-Path $Project $Config.icon
        if (Test-Path -LiteralPath $icon) { $files.Add((Get-Item -LiteralPath $icon -Force)) }
    }
    $files.Add((Get-Item -LiteralPath (Join-Path $Project '.ds-game-dev\project.json') -Force))
    return ,$files
}

function Get-DsRomPath {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string]$Project)
    if ($Config.rom) { return (Join-Path $Project $Config.rom) }
    return (Join-Path $Project 'game.nds')
}

function Get-DsBuildInfoPath {
    param([Parameter(Mandatory)] [string]$Project, [Parameter(Mandatory)] [string]$RomPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($RomPath)
    return (Join-Path $Project ".ds-game-dev\build\out\$stem.buildinfo.json")
}
