[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectPath)
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$config = Join-Path $project '.ds-game-dev\project.json'
if (-not (Test-Path -LiteralPath $config)) { throw "Falta el contrato del proyecto: $config" }
$commands = (Get-Content -Raw $config | ConvertFrom-Json).hostTests
if (-not $commands) { Write-Output 'DS_HOST_TESTS=SKIP reason=no-host-tests'; exit 0 }
Push-Location $project
try {
    foreach ($command in $commands) {
        Write-Output "DS_HOST_TEST_COMMAND=$command"
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command
        if ($LASTEXITCODE -ne 0) { throw "Falló el test host: $command" }
    }
} finally { Pop-Location }
Write-Output "DS_HOST_TESTS=PASS project=$project"
