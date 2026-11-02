[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [string]$OutputRom,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$configPath = Join-Path $project '.ds-game-dev\project.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Falta el contrato del proyecto: $configPath" }
$config = Get-Content -Raw $configPath | ConvertFrom-Json
$image = if ($config.blocksdsImage) { $config.blocksdsImage } else { 'skylyrac/blocksds:slim-latest' }
$template = if ($config.buildTemplate -eq 'skill-default') {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\blocksds-test'
} else {
    Join-Path $project $config.buildTemplate
}
if (-not (Test-Path -LiteralPath $template)) { throw "Falta la plantilla de build: $template" }
$buildRoot = Join-Path $project '.ds-game-dev\build'

# Native commands write to stderr on failure; under 'Stop' Windows PowerShell
# 5.1 would turn that into a terminating error before we can explain it.
$ErrorActionPreference = 'Continue'
docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker no responde. Arranca Docker Desktop y repite la build.' }
$imageId = docker image inspect $image --format '{{.Id}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\load-blocksds-image.ps1')
    $imageId = docker image inspect $image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "La imagen BlocksDS no está cargada y no se pudo cargar desde el paquete offline." }
}
$ErrorActionPreference = 'Stop'

# Incremental build: the build tree is kept between runs so make only
# recompiles what changed. It is wiped when anything that is not tracked by
# make's dependency files changes (template, project contract, image).
$templateHash = Get-ChildItem -LiteralPath $template -Recurse -File | Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($template.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
$stampText = (@("image=$imageId", "config=$((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash)") + $templateHash) -join "`n"
$stampPath = Join-Path $buildRoot '.ds-build-stamp'
$previousStamp = if (Test-Path -LiteralPath $stampPath) { Get-Content -Raw -LiteralPath $stampPath } else { $null }
if ($Clean -or $previousStamp -ne $stampText) {
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$now = Get-Date
$synced = 0
# Index of what each build file was copied from ("length:mtime" of the
# source), kept outside the copied trees so nothing leaks into the ROM.
$indexPath = Join-Path $buildRoot '.ds-build-index.json'
$index = @{}
if (Test-Path -LiteralPath $indexPath) {
    (Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $index[$_.Name] = $_.Value }
}
# Copy $Source to $Destination only when the source changed since the last
# copy, and stamp the copy with the current time so make sees it as newer
# than its objects even when the source carries an older date (git checkout).
function Sync-File([string]$Source, [string]$Destination) {
    $src = Get-Item -LiteralPath $Source -Force
    $signature = "$($src.Length):$($src.LastWriteTimeUtc.Ticks)"
    if ($index[$Destination] -eq $signature -and (Test-Path -LiteralPath $Destination)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    (Get-Item -LiteralPath $Destination).LastWriteTime = $now
    $index[$Destination] = $signature
    $script:synced++
}
# Mirror a directory: sync every file and drop files no longer in the source.
function Sync-Tree([string]$Source, [string]$Destination) {
    $wanted = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
        $target = Join-Path $Destination $file.FullName.Substring($Source.Length).TrimStart('\')
        $wanted[$target] = $true
        Sync-File $file.FullName $target
    }
    if (Test-Path -LiteralPath $Destination) {
        foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File -Force) {
            if (-not $wanted.ContainsKey($file.FullName)) {
                Remove-Item -LiteralPath $file.FullName -Force
                $index.Remove($file.FullName)
                $script:removed++
            }
        }
    }
}
function Sync-All {
    foreach ($file in Get-ChildItem -LiteralPath $template -Recurse -File -Force) {
        Sync-File $file.FullName (Join-Path $buildRoot $file.FullName.Substring($template.Length).TrimStart('\'))
    }
    foreach ($item in $config.copy) {
        $source = (Resolve-Path -LiteralPath (Join-Path $project $item.source)).Path
        $destination = Join-Path $buildRoot $item.destination
        if (Test-Path -LiteralPath $source -PathType Container) { Sync-Tree $source $destination }
        else { Sync-File $source $destination }
    }
}

$removed = 0
Sync-All
if ($removed -gt 0) {
    # A deleted source leaves its object behind and make would not relink,
    # so the ROM would keep the removed code. Deletions are rare: rebuild.
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    $index = @{}
    $synced = 0
    Sync-All
}
Set-Content -LiteralPath $stampPath -Value $stampText -NoNewline
$index | ConvertTo-Json -Compress | Set-Content -LiteralPath $indexPath

$ErrorActionPreference = 'Continue'
docker run --rm -v "${buildRoot}:/source" -w /source $image sh -c 'make -j$(nproc)'
$makeExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($makeExit -ne 0) { throw 'La compilación BlocksDS falló.' }
$built = Join-Path $buildRoot $config.outputRom
if (-not (Test-Path -LiteralPath $built)) { throw "La build no produjo $($config.outputRom)" }
$destinationRom = if ($OutputRom) { $OutputRom } elseif ($config.rom) { Join-Path $project $config.rom } else { Join-Path $project 'game.nds' }
Copy-Item -LiteralPath $built -Destination $destinationRom -Force
Write-Output "DS_BUILD=PASS rom=$destinationRom image=$image synced=$synced removed=$removed"
