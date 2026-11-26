[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$Variant,
    # Contract file, or its name (then <project>\.ds-game-dev\partial\<name>.txt). Its folder holds catalogo.json.
    [Parameter(Mandatory)] [string]$Contract,
    # Scenarios (files or * patterns, relative to the project) that play what the ROM is for.
    # Mandatory: the verification only proves what they open; nothing is guessed.
    [string[]]$Scenarios,
    # Default: <rom>-<variant>-<contract>.nds next to the project's ROM.
    [string]$OutputRom,
    # Instead of verifying: runs the scenarios on a probe build with ALL of nitrofiles/ and prints the
    # concepts they opened (a starting point for a contract).
    [switch]$Record,
    # Contact sheet of each scenario's captures.
    [switch]$Look
)
# Partial ROM = contract of concepts + catalogo.json (see references/partial-rom.md). Builds with the nitro probe
# and then plays the scenarios on it: PARTIAL_VERIFY=FAIL if the game tried to open a nitro:/ file that is not in the ROM.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'project-common.ps1')
. (Join-Path $PSScriptRoot 'partial\partial-common.ps1')
$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
$config = Get-DsProjectConfig $project
$buildScript = Join-Path $PSScriptRoot 'build-project.ps1'
$runScript = Join-Path $PSScriptRoot 'run-scenario.ps1'
$nitroRoot = Join-Path $project 'nitrofiles'
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (-not $Scenarios -or $Scenarios.Count -eq 0) {
    throw 'Falta -Scenarios: indica al menos un escenario (o patron) que juegue lo que la ROM debe poder hacer.'
}
$contractPath = if (Test-Path -LiteralPath $Contract -PathType Leaf) { (Resolve-Path -LiteralPath $Contract).Path }
                else { Join-Path $project ".ds-game-dev\partial\$Contract.txt" }
$scenarioFiles = @(foreach ($s in $Scenarios) {
    $p = if ([IO.Path]::IsPathRooted($s)) { $s } else { Join-Path $project $s }
    $hit = @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue)
    if ($hit.Count -eq 0) { throw "Ningun escenario coincide con: $s" }
    $hit.FullName
}) | Select-Object -Unique

$work = Join-Path $project "artifacts\partial\$([IO.Path]::GetFileNameWithoutExtension($contractPath))"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Get-OutFile([string]$Stem, [string]$Ext) { "../../../.ds-game-dev/build/out/$Stem.$Ext" }   # relative to $work\<x>.json
# Copy of a scenario with state.elf at <elf> and a final state_capture that reads <symbol> as <words> u32 fields.
function Write-TempScenario([string]$Source, [string]$Path, [string]$Elf, [string]$Symbol, [int]$Words) {
    $sc = Get-Content -Raw -LiteralPath $Source | ConvertFrom-Json
    if (-not $sc.PSObject.Properties['state']) { $sc | Add-Member -NotePropertyName state -NotePropertyValue ([pscustomobject]@{}) }
    $st = $sc.state
    foreach ($k in 'map', 'map_path') { if ($st.PSObject.Properties[$k]) { $st.PSObject.Properties.Remove($k) } }
    if ($st.PSObject.Properties['elf']) { $st.elf = $Elf } else { $st | Add-Member -NotePropertyName elf -NotePropertyValue $Elf }
    if (-not $st.PSObject.Properties['symbols']) { $st | Add-Member -NotePropertyName symbols -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $st.PSObject.Properties['fields']) { $st | Add-Member -NotePropertyName fields -NotePropertyValue ([pscustomobject]@{}) }
    $first = ($st.symbols.PSObject.Properties | Select-Object -First 1)
    $st.symbols | Add-Member -NotePropertyName __np -NotePropertyValue $Symbol -Force
    for ($i = 0; $i -lt $Words; $i++) {
        $st.fields | Add-Member -NotePropertyName "__np$i" -NotePropertyValue ([pscustomobject]@{ symbol = '__np'; offset = 4 * $i; type = 'u32' }) -Force
    }
    if (-not $st.PSObject.Properties['default_symbol']) {
        $st | Add-Member -NotePropertyName default_symbol -NotePropertyValue $(if ($first) { $first.Name } else { '__np' })
    }
    $sc.steps = @($sc.steps) + @([pscustomobject]@{ state_capture = '__probe' })
    [IO.File]::WriteAllText($Path, ($sc | ConvertTo-Json -Depth 30 -Compress), $utf8)
}
# Plays every scenario on <rom> and returns, per scenario, the paths of the probe list <symbol> (NUL-separated, 4 + data bytes).
function Read-ProbeList([string]$Rom, [string]$Stem, [string]$Symbol, [int]$Words) {
    foreach ($sf in $scenarioFiles) {
        $name = [IO.Path]::GetFileNameWithoutExtension($sf)
        $tmp = Join-Path $work "$name.json"
        Write-TempScenario $sf $tmp (Get-OutFile $Stem 'elf') $Symbol $Words
        $out = Join-Path $work "$name-out"
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        $runArgs = @('-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runScript, '-ScenarioPath', $tmp, '-ProjectPath', $project, '-RomPath', $Rom, '-OutputPath', $out)
        if ($Look) { $runArgs += '-Look' }
        & powershell @runArgs | Out-Host
        $code = $LASTEXITCODE
        $manifestPath = Join-Path $out 'manifest.json'
        if ($code -ge 2 -or -not (Test-Path -LiteralPath $manifestPath)) { throw "El escenario $name fallo (exit $code); mira $out" }
        $sample = (Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).state_samples.__probe
        if (-not $sample) { throw "El escenario $name no llego al final (sin muestra de la sonda); mira $out\manifest.json" }
        $bytes = New-Object byte[] (4 * $Words)
        for ($i = 0; $i -lt $Words; $i++) {
            [BitConverter]::GetBytes([uint32]([int64]$sample."__np$i" -band 0xFFFFFFFFL)).CopyTo($bytes, 4 * $i)
        }
        $len = [BitConverter]::ToUInt32($bytes, 0)
        if ($len -gt (4 * $Words - 4)) { throw "Lista de la sonda corrupta en $name (len=$len)." }
        $paths = if ($len -eq 0) { @() } else { @([Text.Encoding]::UTF8.GetString($bytes, 4, [int]$len).Split([char]0) | Where-Object { $_ }) }
        [pscustomobject]@{ Scenario = $name; Paths = $paths; Exit = $code }
    }
}
function Get-RomOf([string]$Suffix) {
    $base = Get-DsRomPath $config $project
    Join-Path (Split-Path -Parent $base) ("{0}-{1}.nds" -f [IO.Path]::GetFileNameWithoutExtension($base), $Suffix)
}

if ($Record) {
    Write-Output "== build con sonda y nitrofiles/ completo ($Variant) =="
    & powershell -NonInteractive -ExecutionPolicy Bypass -File $buildScript -ProjectPath $project -Variant $Variant -NitroTrace | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'La build de grabacion fallo.' }
    $rom = Get-RomOf "$Variant-trace"
    $catalog = Read-PartialCatalog $contractPath
    $opened = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in (Read-ProbeList $rom ([IO.Path]::GetFileNameWithoutExtension($rom)) 'g_nitro_trace' 3072)) { foreach ($p in $r.Paths) { [void]$opened.Add($p) } }
    $need = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($p in $opened) {
        if ($p -eq 'soundbank.bin' -or -not (Test-Path -LiteralPath (Join-Path $nitroRoot $p) -PathType Leaf)) { continue }
        foreach ($m in (Find-PartialConcepts $catalog $p)) { [void]$need.Add($m.Concept) }
    }
    Write-Output "PARTIAL_RECORD opened=$($opened.Count) concepts: $($need -join ' ')"
    Write-Output '(solo lo que los escenarios tocaron; anade a mano lo que no jueguen, p.ej. remates)'
    exit 0
}

Write-Output "== build parcial ($Variant, contrato $contractPath) =="
$buildArgs = @('-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $buildScript, '-ProjectPath', $project, '-Variant', $Variant, '-Contract', $contractPath)
if ($OutputRom) { $buildArgs += @('-OutputRom', $OutputRom) }
$buildOut = & powershell @buildArgs
$buildOut | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'La build parcial fallo.' }
$romLine = @($buildOut | Where-Object { $_ -match '^DS_BUILD=PASS rom=(.+?) variant=' }) | Select-Object -Last 1
if (-not $romLine -or $romLine -notmatch '^DS_BUILD=PASS rom=(.+?) variant=') { throw 'No se pudo leer la ROM de la build.' }
$rom = $Matches[1]
$resolved = Resolve-PartialContract $contractPath $nitroRoot

Write-Output "== verificacion: $($scenarioFiles.Count) escenario(s) en la ROM parcial =="
$results = @(Read-ProbeList $rom ([IO.Path]::GetFileNameWithoutExtension($rom)) 'g_nitro_missing' 512)
$bad = [System.Collections.Generic.SortedDictionary[string,string]]::new()
$optional = New-Object System.Collections.Generic.SortedSet[string]
$notInGame = New-Object System.Collections.Generic.SortedSet[string]
foreach ($r in $results) {
    foreach ($p in $r.Paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $nitroRoot $p.Replace('/', '\')) -PathType Leaf)) { [void]$notInGame.Add($p); continue }
        $m = @(Find-PartialConcepts $resolved.Catalog $p)
        if (@($m | Where-Object { $_.Entry.Optional }).Count -gt 0) { [void]$optional.Add($p); continue }
        $hint = (@($m | ForEach-Object { @($_.Concept) + @($_.Entry.Con) }) | Select-Object -Unique) -join ', '
        $bad[$p] = "$($r.Scenario); anade: $hint"
    }
}
$bytes = (Get-Item -LiteralPath $rom).Length
foreach ($p in $optional) { Write-Output "  opcional ausente (el juego tiene respaldo): $p" }
foreach ($p in $notInGame) { Write-Output "  ausente tambien en nitrofiles/ del juego completo (no es culpa del contrato): $p" }
foreach ($k in $bad.Keys) { Write-Output "  FALTA $k  ($($bad[$k]))" }
$status = if ($bad.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Output ("PARTIAL_VERIFY=$status contract=$($resolved.Name) concepts=$($resolved.Concepts -join ',') files=$($resolved.Files.Count) scenarios=$($results.Count) missing=$($bad.Count) rom=$rom size_mb={0:N1}" -f ($bytes / 1MB))
if ($bad.Count -gt 0) { Write-Output ('PARTIAL_MISSING ' + ($bad.Keys -join ' ')); exit 1 }
Write-Output "Subir: upload-rom.ps1 -ProjectPath $project -RomPath $rom -ConfirmUpload (sube como romUploadName)"
