[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ScenarioPath,
    [string]$ProjectPath,
    # Defaults to the project's "rom" from .ds-game-dev/project.json.
    [string]$RomPath,
    # Defaults to <project>\artifacts\scenarios\<scenario>-<timestamp>.
    [string]$OutputPath,
    [string]$MapPath,
    [string]$StatesDir,
    [switch]$Jit,
    [switch]$NoSkipRender
)
# Prints only DSM_ lines; the full raw output goes to <out>\emulator.log.
# Exit code: 0 pass, 1 fail/no assertions, 2 error.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
. (Join-Path $PSScriptRoot 'project-common.ps1')

if (-not (Test-Path -LiteralPath $ScenarioPath)) { throw "Escenario no encontrado: $ScenarioPath" }
$scenario = (Resolve-Path -LiteralPath $ScenarioPath).Path
$project = $null
if ($ProjectPath) {
    $project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
    $config = Get-DsProjectConfig $project
    if (-not $RomPath) { $RomPath = Get-DsRomPath $config $project }
}
if (-not $RomPath) { throw 'Falta -RomPath (o -ProjectPath con "rom" en project.json).' }
if (-not $MapPath -and $project) {
    $info = Get-DsBuildInfoPath $project $RomPath
    if (Test-Path -LiteralPath $info) {
        $map = (Get-Content -Raw -LiteralPath $info | ConvertFrom-Json).map
        if ($map -and (Test-Path -LiteralPath $map)) { $MapPath = $map }
    }
}
if (-not $OutputPath) {
    $base = if ($project) { Join-Path $project 'artifacts\scenarios' } else { Join-Path $env:TEMP 'ds-game-dev\scenarios' }
    $OutputPath = Join-Path $base ("{0}-{1}" -f [IO.Path]::GetFileNameWithoutExtension($scenario), (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
$exit = Invoke-DsRunner -SkillRoot $root -RomPath $RomPath -ScenarioPaths @($scenario) -OutputPath $OutputPath `
    -MapPath $MapPath -StatesDir $StatesDir -Jit:$Jit -NoSkipRender:$NoSkipRender
exit $exit
