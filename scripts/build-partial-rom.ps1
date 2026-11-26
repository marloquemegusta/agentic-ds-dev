[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$Variant,
    # Scenario that plays the room (any scenario that boots <Variant>); it is only used to record.
    [Parameter(Mandatory)] [string]$Scenario,
    # Skips the recording: rebuilds the partial ROM from the existing list (e.g. after editing it by hand).
    [switch]$NoRecord,
    # After building, runs the scenario on the partial ROM and prints a contact sheet of its captures.
    [switch]$Verify
)
# Partial ROM: record which nitro:/ files the game opens while playing a scenario, keep the list in
# <project>\.ds-game-dev\partial\<Variant>.txt (union with the previous one) and build
# <rom>-<Variant>-parcial.nds with only those files. See references/partial-rom.md.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-common.ps1')
$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
$scenarioFull = (Resolve-Path -LiteralPath $Scenario).Path
$config = Get-DsProjectConfig $project
$buildScript = Join-Path $PSScriptRoot 'build-project.ps1'
$runScript = Join-Path $PSScriptRoot 'run-scenario.ps1'
$nitroDir = Join-Path $project 'nitrofiles'
$listDir = Join-Path $project '.ds-game-dev\partial'
$listPath = Join-Path $listDir "$Variant.txt"
$work = Join-Path $project "artifacts\partial\$Variant"
New-Item -ItemType Directory -Force -Path $listDir, $work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

# The runner resolves state.elf relative to the scenario (artifacts\partial\<variant>\, 3 levels below the project).
function Get-OutFile([string]$Stem, [string]$Ext) { "../../../.ds-game-dev/build/out/$Stem.$Ext" }
function Get-RomOf([string]$Suffix) {
    $base = Get-DsRomPath $config $project
    Join-Path (Split-Path -Parent $base) ("{0}-{1}.nds" -f [IO.Path]::GetFileNameWithoutExtension($base), $Suffix)
}
# Copy of the scenario with the state pointing at <elf>; with -Trace it also reads g_nitro_trace
# (12288 bytes as u32 fields) in a final state_capture named __nitro.
function Write-TempScenario([string]$Path, [string]$Elf, [switch]$Trace) {
    $sc = Get-Content -Raw -LiteralPath $scenarioFull | ConvertFrom-Json
    if (-not $sc.PSObject.Properties['state']) { $sc | Add-Member -NotePropertyName state -NotePropertyValue ([pscustomobject]@{}) }
    $st = $sc.state
    foreach ($k in 'map', 'map_path') { if ($st.PSObject.Properties[$k]) { $st.PSObject.Properties.Remove($k) } }
    if ($st.PSObject.Properties['elf']) { $st.elf = $Elf } else { $st | Add-Member -NotePropertyName elf -NotePropertyValue $Elf }
    if ($Trace) {
        if (-not $st.PSObject.Properties['symbols']) { $st | Add-Member -NotePropertyName symbols -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $st.PSObject.Properties['fields']) { $st | Add-Member -NotePropertyName fields -NotePropertyValue ([pscustomobject]@{}) }
        $hadDefault = $st.PSObject.Properties['default_symbol'] -or $st.symbols.PSObject.Properties.Count -eq 1
        $first = ($st.symbols.PSObject.Properties | Select-Object -First 1)
        $st.symbols | Add-Member -NotePropertyName __nt -NotePropertyValue 'g_nitro_trace' -Force
        for ($i = 0; $i -lt 3072; $i++) {
            $st.fields | Add-Member -NotePropertyName "__nt$i" -NotePropertyValue ([pscustomobject]@{ symbol = '__nt'; offset = 4 * $i; type = 'u32' }) -Force
        }
        if (-not $st.PSObject.Properties['default_symbol']) {
            $ds = if ($first) { $first.Name } else { '__nt' }
            $st | Add-Member -NotePropertyName default_symbol -NotePropertyValue $ds
        }
        $sc.steps = @($sc.steps) + @([pscustomobject]@{ state_capture = '__nitro' })
        if ($sc.PSObject.Properties['assertions']) { $sc.PSObject.Properties.Remove('assertions') }
    }
    [IO.File]::WriteAllText($Path, ($sc | ConvertTo-Json -Depth 30 -Compress), $utf8)
}

$traceRom = Get-RomOf "$Variant-trace"
if (-not $NoRecord) {
    Write-Output "== 1/4 build de grabacion ($Variant, NITRO_TRACE) =="
    & powershell -NonInteractive -ExecutionPolicy Bypass -File $buildScript -ProjectPath $project -Variant $Variant -NitroTrace
    if ($LASTEXITCODE -ne 0) { throw 'La build de grabacion fallo.' }
    $traceStem = [IO.Path]::GetFileNameWithoutExtension($traceRom)
    $tmpScenario = Join-Path $work 'record.json'
    Write-TempScenario $tmpScenario (Get-OutFile $traceStem 'elf') -Trace
    Write-Output '== 2/4 grabando en DeSmuME =='
    $outPath = Join-Path $work 'record-out'
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Recurse -Force }
    & powershell -NonInteractive -ExecutionPolicy Bypass -File $runScript -ScenarioPath $tmpScenario -ProjectPath $project -RomPath $traceRom -OutputPath $outPath
    $code = $LASTEXITCODE
    $manifestPath = Join-Path $outPath 'manifest.json'
    if ($code -ge 2 -or -not (Test-Path -LiteralPath $manifestPath)) { throw "El escenario de grabacion fallo (exit $code); mira $outPath" }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $sample = $manifest.state_samples.__nitro
    if (-not $sample) { throw "El escenario no llego al final (sin muestra __nitro); mira $outPath\manifest.json" }
    $len = [uint32]$sample.__nt0
    if ($len -eq 0 -or $len -gt 12284) { throw "Grabacion vacia o corrupta (len=$len)." }
    $bytes = New-Object byte[] (4 * 3072)
    for ($i = 0; $i -lt 3072; $i++) {
        [BitConverter]::GetBytes([uint32]([int64]$sample."__nt$i" -band 0xFFFFFFFFL)).CopyTo($bytes, 4 * $i)
    }
    $recorded = [Text.Encoding]::UTF8.GetString($bytes, 4, [int]$len).Split([char]0) | Where-Object { $_ }
    Write-Output '== 3/4 lista =='
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($r in $recorded) {
        if ($r -eq 'soundbank.bin') { continue }   # lo genera la build (maxmod), no vive en nitrofiles/
        if (Test-Path -LiteralPath (Join-Path $nitroDir $r) -PathType Leaf) { $keep.Add($r) }
        else { Write-Output "  (abierto pero no existe en nitrofiles/, se ignora: $r)" }
    }
    $union = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path -LiteralPath $listPath) {
        foreach ($l in (Get-Content -LiteralPath $listPath)) { $t = $l.Trim(); if ($t -and -not $t.StartsWith('#')) { [void]$union.Add($t) } }
    }
    $before = $union.Count
    foreach ($k in $keep) { [void]$union.Add($k) }
    $sorted = [string[]]@($union)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    [IO.File]::WriteAllText($listPath, (($sorted -join "`n") + "`n"), $utf8)
    Write-Output "  grabados: $($keep.Count), lista: $($sorted.Count) (antes $before) -> $listPath"
} elseif (-not (Test-Path -LiteralPath $listPath)) { throw "Falta la lista $listPath (quita -NoRecord)." }

Write-Output '== 4/4 build parcial =='
& powershell -NonInteractive -ExecutionPolicy Bypass -File $buildScript -ProjectPath $project -Variant $Variant -NitroList $listPath
if ($LASTEXITCODE -ne 0) { throw 'La build parcial fallo.' }
$partialRom = Get-RomOf "$Variant-parcial"
$files = @(Get-Content -LiteralPath $listPath | Where-Object { $_.Trim() }).Count
$fullBytes = if (Test-Path -LiteralPath $traceRom) { (Get-Item -LiteralPath $traceRom).Length } else { 0 }
$partBytes = (Get-Item -LiteralPath $partialRom).Length
Write-Output ("PARTIAL_ROM rom=$partialRom list=$listPath files=$files full_mb={0:N1} partial_mb={1:N1}" -f ($fullBytes / 1MB), ($partBytes / 1MB))
Write-Output "Subir: upload-rom.ps1 -ProjectPath $project -RomPath $partialRom -ConfirmUpload (sube como romUploadName)"

if ($Verify) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($partialRom)
    $vScenario = Join-Path $work 'verify.json'
    Write-TempScenario $vScenario (Get-OutFile $stem 'elf')
    $vOut = Join-Path $work 'verify-out'
    if (Test-Path -LiteralPath $vOut) { Remove-Item -LiteralPath $vOut -Recurse -Force }
    & powershell -NonInteractive -ExecutionPolicy Bypass -File $runScript -ScenarioPath $vScenario -ProjectPath $project -RomPath $partialRom -OutputPath $vOut -Look
    Write-Output "VERIFY out=$vOut exit=$LASTEXITCODE"
}
