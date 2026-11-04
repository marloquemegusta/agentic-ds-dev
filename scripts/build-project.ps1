[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    # Relative paths resolve against the project, not the current directory.
    [string]$OutputRom,
    [switch]$Clean,
    # Build variant. 'default' is the shipping build; others (e.g. 'perf') add
    # the defines of project.json "variants".<name>.defines to the compile.
    [string]$Variant = 'default',
    # Extra defines, e.g. -Define PERF_PROFILE=1 (passed as -DNAME=VALUE).
    [string[]]$Define = @()
)

$ErrorActionPreference = 'Stop'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$skillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-common.ps1')

$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
if ($Variant -notmatch '^[A-Za-z0-9_-]+$') { throw "Nombre de variante no valido: $Variant" }
$config = Get-DsProjectConfig $project
$configPath = Join-Path $project '.ds-game-dev\project.json'
$image = if ($config.blocksdsImage) { $config.blocksdsImage } else { 'skylyrac/blocksds:slim-latest' }
$template = Get-DsTemplatePath $config $project
if (-not (Test-Path -LiteralPath $template)) { throw "Falta la plantilla de build: $template" }

# Layout: .ds-game-dev/build/<variant>/ (tree), .ds-game-dev/build/out/ (sidecars).
$buildBase = Join-Path $project '.ds-game-dev\build'
$buildRoot = Join-Path $buildBase $Variant
$outDir = Join-Path $buildBase 'out'
if (Test-Path -LiteralPath (Join-Path $buildBase 'Makefile')) {
    # Old flat layout: wipe it once (everything here is gitignored build output).
    Get-ChildItem -LiteralPath $buildBase -Force |
        Where-Object { $_.Name -notin 'out', 'host-tests' -and -not (Test-Path -LiteralPath (Join-Path $_.FullName '.ds-build-stamp')) } |
        Remove-Item -Recurse -Force
}

# Defines: project-wide, then the variant's, then the command line.
$defineList = New-Object System.Collections.Generic.List[string]
foreach ($d in @($config.defines)) { if ($d) { $defineList.Add("$d") } }
if ($config.variants -and $config.variants.PSObject.Properties[$Variant]) {
    foreach ($d in @($config.variants.$Variant.defines)) { if ($d) { $defineList.Add("$d") } }
}
foreach ($d in $Define) { if ($d) { $defineList.Add("$d") } }
$cflags = ($defineList | ForEach-Object { if ($_.StartsWith('-')) { $_ } else { "-D$_" } }) -join ' '

# Native commands write to stderr on failure; under 'Stop' Windows PowerShell
# 5.1 would turn that into a terminating error before we can explain it.
$ErrorActionPreference = 'Continue'
docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker no responde. Arranca Docker Desktop y repite la build.' }
$imageId = docker image inspect $image --format '{{.Id}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    & (Join-Path $skillRoot 'scripts\load-blocksds-image.ps1')
    $imageId = docker image inspect $image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "La imagen BlocksDS no esta cargada y no se pudo cargar desde el paquete offline." }
}
$ErrorActionPreference = 'Stop'

# Incremental build: the variant tree is kept between runs so make only
# recompiles what changed. It is wiped when anything that is not tracked by
# make's dependency files changes (template, project contract, image, defines).
$templateHash = Get-ChildItem -LiteralPath $template -Recurse -File | Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($template.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
$stampText = (@("image=$imageId", "variant=$Variant", "cflags=$cflags",
    "config=$((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash)") + $templateHash) -join "`n"
$stampPath = Join-Path $buildRoot '.ds-build-stamp'
$previousStamp = if (Test-Path -LiteralPath $stampPath) { Get-Content -Raw -LiteralPath $stampPath } else { $null }
if ($Clean -or $previousStamp -ne $stampText) {
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$now = Get-Date
$synced = 0
$removed = 0
$inputCount = 0
$inputsNewest = [DateTime]::MinValue
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
    $script:inputCount++
    if ($src.LastWriteTimeUtc -gt $script:inputsNewest) { $script:inputsNewest = $src.LastWriteTimeUtc }
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
    $script:inputCount = 0
    $script:inputsNewest = [DateTime]::MinValue
    foreach ($file in Get-ChildItem -LiteralPath $template -Recurse -File -Force) {
        Sync-File $file.FullName (Join-Path $buildRoot $file.FullName.Substring($template.Length).TrimStart('\'))
    }
    foreach ($item in $config.copy) {
        $source = (Resolve-Path -LiteralPath (Join-Path $project $item.source)).Path
        $destination = Join-Path $buildRoot $item.destination
        if (Test-Path -LiteralPath $source -PathType Container) { Sync-Tree $source $destination }
        else { Sync-File $source $destination }
    }
    if ($config.icon) {
        Sync-File (Resolve-Path -LiteralPath (Join-Path $project $config.icon)).Path (Join-Path $buildRoot 'ds-game-icon.png')
    }
    $cfg = Get-Item -LiteralPath $configPath
    $script:inputCount++
    if ($cfg.LastWriteTimeUtc -gt $script:inputsNewest) { $script:inputsNewest = $cfg.LastWriteTimeUtc }
}

Sync-All
if ($removed -gt 0) {
    # A deleted source leaves its object behind and make would not relink,
    # so the ROM would keep the removed code. Deletions are rare: rebuild.
    $removedCount = $removed
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    $index = @{}
    $synced = 0
    $removed = 0
    Sync-All
    $removed = $removedCount
}
Set-Content -LiteralPath $stampPath -Value $stampText -NoNewline
$index | ConvertTo-Json -Compress | Set-Content -LiteralPath $indexPath

# Title/author/icon go to make as command-line variables. Their values travel
# in environment variables so no quoting is needed on the docker command line.
# The Makefile uses them inside a double-quoted shell string, so escape for sh
# first and then double '$' for make.
function Format-MakeShellValue([string]$Value) {
    $v = $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
    return $v.Replace('$', '$$')
}
$makeVars = ''
if ($config.title)    { $env:DS_GAME_TITLE = Format-MakeShellValue "$($config.title)";       $makeVars += ' GAME_TITLE=\"$DS_GAME_TITLE\"' }
if ($config.subtitle) { $env:DS_GAME_SUBTITLE = Format-MakeShellValue "$($config.subtitle)"; $makeVars += ' GAME_SUBTITLE=\"$DS_GAME_SUBTITLE\"' }
if ($config.author)   { $env:DS_GAME_AUTHOR = Format-MakeShellValue "$($config.author)";     $makeVars += ' GAME_AUTHOR=\"$DS_GAME_AUTHOR\"' }
if ($config.icon)     { $makeVars += ' GAME_ICON=ds-game-icon.png' }
$env:CFLAGS = $cflags
$dockerArgs = @('run', '--rm', '-e', 'CFLAGS', '-e', 'DS_GAME_TITLE', '-e', 'DS_GAME_SUBTITLE', '-e', 'DS_GAME_AUTHOR',
    '-v', "${buildRoot}:/source", '-w', '/source', $image, 'sh', '-c', ('make -j$(nproc) -Otarget' + $makeVars))

$logPath = Join-Path $buildRoot 'build.log'
$logLines = New-Object System.Collections.Generic.List[string]
$previousEncoding = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    & docker @dockerArgs 2>&1 | ForEach-Object { $logLines.Add("$_") }
    $makeExit = $LASTEXITCODE
} finally {
    [Console]::OutputEncoding = $previousEncoding
    $ErrorActionPreference = 'Stop'
    Remove-Item Env:\CFLAGS, Env:\DS_GAME_TITLE, Env:\DS_GAME_SUBTITLE, Env:\DS_GAME_AUTHOR -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllLines($logPath, $logLines, (New-Object System.Text.UTF8Encoding($false)))

if ($makeExit -ne 0) {
    $errIdx = @(for ($i = 0; $i -lt $logLines.Count; $i++) {
        if ($logLines[$i] -match '(error:|\*\*\* |undefined reference|ld returned|fatal error)') { $i }
    })
    $shown = New-Object System.Collections.Generic.SortedSet[int]
    if ($errIdx.Count -eq 0) {
        for ($i = [Math]::Max(0, $logLines.Count - 15); $i -lt $logLines.Count; $i++) { [void]$shown.Add($i) }
    } else {
        foreach ($e in ($errIdx | Select-Object -First 3)) {
            for ($i = [Math]::Max(0, $e - 2); $i -le [Math]::Min($logLines.Count - 1, $e + 8); $i++) { [void]$shown.Add($i) }
        }
    }
    foreach ($i in $shown) { Write-Output $logLines[$i] }
    Write-Output "DS_BUILD=FAIL variant=$Variant exit=$makeExit log=$logPath"
    exit 1
}

# Warnings ledger: files recompiled in this run replace their entries, so the
# total covers the whole ROM even when the build was incremental.
$ledgerPath = Join-Path $buildRoot '.ds-build-warnings.json'
$ledger = @{}
if (Test-Path -LiteralPath $ledgerPath) {
    (Get-Content -Raw -LiteralPath $ledgerPath | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $ledger[$_.Name] = @($_.Value) }
}
$current = $null
$runWarnings = @{}
foreach ($line in $logLines) {
    if ($line -match '^\s+(?:CC|CXX|AS|ASM)\.\d\s+(\S+)') {
        $current = $Matches[1]
        $ledger[$current] = @()
        $runWarnings[$current] = New-Object System.Collections.Generic.List[string]
    } elseif ($line -match '^\s+(?:LD|ARM7ELF|NDSTOOL|ROM)\b') {
        $current = '(link)'
        $ledger[$current] = @()
        if (-not $runWarnings.ContainsKey($current)) { $runWarnings[$current] = New-Object System.Collections.Generic.List[string] }
    } elseif ($line -match '^\S.*\bwarning:') {
        $key = if ($current) { $current } else { '(other)' }
        if (-not $runWarnings.ContainsKey($key)) { $runWarnings[$key] = New-Object System.Collections.Generic.List[string] }
        if (-not $runWarnings[$key].Contains($line)) { $runWarnings[$key].Add($line) }
    }
}
$printed = New-Object System.Collections.Generic.HashSet[string]
foreach ($key in $runWarnings.Keys) {
    $ledger[$key] = @($runWarnings[$key])
    foreach ($w in $runWarnings[$key]) { if ($printed.Add($w)) { Write-Output $w } }
}
$newWarnings = $printed.Count
$all = New-Object System.Collections.Generic.HashSet[string]
$warnFiles = 0
foreach ($key in @($ledger.Keys)) {
    $entries = @($ledger[$key])
    if ($entries.Count -eq 0) { $ledger.Remove($key); continue }
    $warnFiles++
    foreach ($w in $entries) { [void]$all.Add($w) }
}
$totalWarnings = $all.Count
[IO.File]::WriteAllText($ledgerPath, ($ledger | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))

# Locate the products. BlocksDS puts the ROM at the tree root and ELF/map in build/.
$built = Join-Path $buildRoot $config.outputRom
if (-not (Test-Path -LiteralPath $built)) { throw "La build no produjo $($config.outputRom)" }
$destinationRom = if ($OutputRom) {
    if ([IO.Path]::IsPathRooted($OutputRom)) { $OutputRom } else { Join-Path $project $OutputRom }
} else {
    $base = Get-DsRomPath $config $project
    if ($Variant -eq 'default') { $base }
    else { Join-Path (Split-Path -Parent $base) ("{0}-{1}.nds" -f [IO.Path]::GetFileNameWithoutExtension($base), $Variant) }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationRom) | Out-Null
Copy-Item -LiteralPath $built -Destination $destinationRom -Force
# Copy-Item keeps the old mtime on a no-op build; the ROM is "as of now".
(Get-Item -LiteralPath $destinationRom).LastWriteTime = Get-Date
$romStem = [IO.Path]::GetFileNameWithoutExtension($destinationRom)

$nameStem = [IO.Path]::GetFileNameWithoutExtension($config.outputRom)
$elfOut = ''
$mapOut = ''
foreach ($ext in 'elf', 'map') {
    $src = Join-Path $buildRoot "build\$nameStem.$ext"
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $outDir "$romStem.$ext"
        Copy-Item -LiteralPath $src -Destination $dst -Force
        if ($ext -eq 'elf') { $elfOut = $dst } else { $mapOut = $dst }
    }
}
$info = [ordered]@{
    rom = $destinationRom
    romSha256 = (Get-FileHash -LiteralPath $destinationRom -Algorithm SHA256).Hash.ToLowerInvariant()
    variant = $Variant
    builtAt = (Get-Date).ToUniversalTime().ToString('o')
    image = $image
    imageId = "$imageId".Trim()
    elf = $elfOut
    map = $mapOut
    inputsNewestUtc = $inputsNewest.ToUniversalTime().ToString('o')
    inputCount = $inputCount
    warnings = [ordered]@{ total = $totalWarnings; files = $warnFiles }
}
[IO.File]::WriteAllText((Join-Path $outDir "$romStem.buildinfo.json"), ($info | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

$seconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds)
Write-Output "DS_BUILD=PASS rom=$destinationRom variant=$Variant synced=$synced removed=$removed warnings=$totalWarnings new_warnings=$newWarnings seconds=$seconds"
