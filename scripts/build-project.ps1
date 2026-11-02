[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [string]$OutputRom
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
if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
Get-ChildItem -LiteralPath $template -Force | Copy-Item -Destination $buildRoot -Recurse -Force
foreach ($item in $config.copy) {
    $source = Join-Path $project $item.source
    $destination = Join-Path $buildRoot $item.destination
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}
$imageId = docker image inspect $image --format '{{.Id}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\load-blocksds-image.ps1')
    docker image inspect $image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "La imagen BlocksDS no está cargada y no se pudo cargar desde el paquete offline." }
}
docker run --rm -v "${buildRoot}:/source" -w /source $image make
if ($LASTEXITCODE -ne 0) { throw 'La compilación BlocksDS falló.' }
$built = Join-Path $buildRoot $config.outputRom
if (-not (Test-Path -LiteralPath $built)) { throw "La build no produjo $($config.outputRom)" }
$destinationRom = if ($OutputRom) { $OutputRom } elseif ($config.rom) { Join-Path $project $config.rom } else { Join-Path $project 'game.nds' }
Copy-Item -LiteralPath $built -Destination $destinationRom -Force
Write-Output "DS_BUILD=PASS rom=$destinationRom image=$image"
