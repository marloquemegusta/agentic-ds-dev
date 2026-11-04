[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [string]$RomPath,
    # Wildcard on the scenario file name (without .json), e.g. 'fire_*'.
    [string]$Filter,
    # Only scenarios whose JSON has this tag in its "tags" array.
    [string]$Tag,
    # Defaults to <project>\artifacts\suites\<timestamp>.
    [string]$OutputPath,
    [string]$MapPath,
    [string]$StatesDir,
    [switch]$Jit,
    [switch]$NoSkipRender
)
# Runs every scenario of the project in ONE runner process. Prints DSM_ lines
# and a compact table of the non-passing scenarios. Exit: 0 pass, 1 fail, 2 error.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
. (Join-Path $PSScriptRoot 'project-common.ps1')

$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
$config = Get-DsProjectConfig $project
if (-not $RomPath) { $RomPath = Get-DsRomPath $config $project }
$dirName = if ($config.scenarioDirectory) { $config.scenarioDirectory } else { 'scenarios' }
$dir = Join-Path $project $dirName
if (-not (Test-Path -LiteralPath $dir)) { throw "No existe el directorio de escenarios: $dir" }
$files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.template.json' })
if ($Filter) { $files = @($files | Where-Object { $_.BaseName -like $Filter }) }
if ($Tag) {
    $files = @($files | Where-Object {
        try { $t = (Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json).tags; $t -and ($t -contains $Tag) } catch { $false }
    })
}
if ($files.Count -eq 0) { Write-Output 'DSM_SUITE_RESULT=NO_SCENARIOS count=0'; exit 1 }
if (-not $MapPath) {
    $info = Get-DsBuildInfoPath $project $RomPath
    if (Test-Path -LiteralPath $info) {
        $map = (Get-Content -Raw -LiteralPath $info | ConvertFrom-Json).map
        if ($map -and (Test-Path -LiteralPath $map)) { $MapPath = $map }
    }
}
if (-not $OutputPath) { $OutputPath = Join-Path $project ('artifacts\suites\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

$exit = Invoke-DsRunner -SkillRoot $root -RomPath $RomPath -ScenarioPaths @($files.FullName) -OutputPath $OutputPath `
    -MapPath $MapPath -StatesDir $StatesDir -Jit:$Jit -NoSkipRender:$NoSkipRender

# Compact table of whatever did not pass, from each scenario's result.json.
$bad = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    $rj = Join-Path $OutputPath "$($f.BaseName)\result.json"
    # A single-scenario run writes straight into the output directory.
    if (-not (Test-Path -LiteralPath $rj) -and $files.Count -eq 1) { $rj = Join-Path $OutputPath 'result.json' }
    if (-not (Test-Path -LiteralPath $rj)) { $bad.Add(("{0}`tERROR`tno result.json" -f $f.BaseName)); continue }
    try {
        $r = Get-Content -Raw -LiteralPath $rj | ConvertFrom-Json
        $status = if ($r.status) { "$($r.status)" } elseif ($r.result) { "$($r.result)" } else { '?' }
        if ($status -ne 'PASS') {
            $why = ''
            foreach ($k in 'failed', 'failures', 'errors', 'message', 'error') {
                if ($r.PSObject.Properties[$k] -and $r.$k) {
                    $first = @($r.$k) | Select-Object -First 1
                    $why = if ($first -is [string]) { $first }
                        elseif ($first.PSObject.Properties['check']) {
                            "$($first.check) expected=$($first.expected | ConvertTo-Json -Compress) actual=$($first.actual | ConvertTo-Json -Compress)"
                        } else { $first | ConvertTo-Json -Compress }
                    break
                }
            }
            if ($why.Length -gt 120) { $why = $why.Substring(0, 120) }
            $bad.Add(("{0}`t{1}`t{2}" -f $f.BaseName, $status, ($why -replace '\s+', ' ')))
        }
    } catch { $bad.Add(("{0}`tERROR`tresult.json ilegible" -f $f.BaseName)) }
}
if ($bad.Count -gt 0) {
    Write-Output 'DS_SUITE_NONPASS=scenario<TAB>status<TAB>detail'
    $bad | ForEach-Object { Write-Output $_ }
}
Write-Output "DS_SUITE_OUT=$OutputPath"
exit $exit
