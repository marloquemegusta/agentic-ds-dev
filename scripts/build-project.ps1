[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    # Relative paths resolve against the project, not the current directory.
    [string]$OutputRom,
    [switch]$Clean,
    # Build variant. 'default' is the shipping build; others (e.g. 'perf') add
    # the defines of project.json "variants".<name>.defines to the compile.
    # Several variants (-Variant a,b,c) are built in parallel, one process each.
    [string[]]$Variant = @('default'),
    # Extra defines, e.g. -Define PERF_PROFILE=1 (passed as -DNAME=VALUE).
    [string[]]$Define = @(),
    # Partial ROM, see references/partial-rom.md. -Contract <file>: nitrofiles/ only gets the files of the
    # concepts the contract lists (catalogo.json next to it) and the build carries the nitro probe.
    # Own tree and output: <rom>-<variant>-<contract>.nds. -NitroTrace: probe build with the full nitrofiles/
    # (tree <variant>-trace), used by build-partial-rom.ps1 -Record.
    [switch]$NitroTrace,
    [string]$Contract
)

$ErrorActionPreference = 'Stop'
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$skillRoot = Split-Path -Parent $PSScriptRoot
function Write-Trace([string]$What) { if ($env:DS_BUILD_TRACE) { [Console]::Error.WriteLine(('[trace {0:N1}s] {1}' -f $stopwatch.Elapsed.TotalSeconds, $What)) } }
. (Join-Path $PSScriptRoot 'project-common.ps1')

$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')

# -Variant a,b,c: one child process per variant (own volume, container and
# output files), all at once. Prints each child's output and fails if any did.
$Variant = @($Variant | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | Select-Object -Unique)
if ($Variant.Count -eq 0) { $Variant = @('default') }
if ($Variant.Count -gt 1) {
    if ($OutputRom) { throw '-OutputRom no se puede combinar con varias variantes.' }
    if ($Define.Count -gt 0) { throw '-Define no se puede combinar con varias variantes.' }
    if ($NitroTrace -or $Contract) { throw '-NitroTrace/-Contract no se pueden combinar con varias variantes.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dsbuild-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $jobs = foreach ($v in $Variant) {
        if ($v -notmatch '^[A-Za-z0-9_-]+$') { throw "Nombre de variante no valido: $v" }
        $argList = @('-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ProjectPath', "`"$project`"", '-Variant', $v)
        if ($Clean) { $argList += '-Clean' }
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $tmp "$v.out") -RedirectStandardError (Join-Path $tmp "$v.err")
        $null = $proc.Handle   # keeps ExitCode readable after the process ends
        [pscustomobject]@{ Variant = $v; Proc = $proc }
    }
    $failed = 0
    foreach ($j in $jobs) {
        $j.Proc.WaitForExit()
        Get-Content -LiteralPath (Join-Path $tmp "$($j.Variant).out") | Write-Output
        Get-Content -LiteralPath (Join-Path $tmp "$($j.Variant).err") | Write-Output
        if ($j.Proc.ExitCode -ne 0) { $failed++ }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $total = [Math]::Round($stopwatch.Elapsed.TotalSeconds)
    Write-Output "DS_BUILD_ALL=$(if ($failed) { 'FAIL' } else { 'PASS' }) variants=$($Variant -join ',') failed=$failed seconds=$total"
    if ($failed) { exit 1 }
    exit 0
}
[string]$Variant = $Variant[0]
if ($Variant -notmatch '^[A-Za-z0-9_-]+$') { throw "Nombre de variante no valido: $Variant" }
$config = Get-DsProjectConfig $project
$configPath = Join-Path $project '.ds-game-dev\project.json'
$image = if ($config.blocksdsImage) { $config.blocksdsImage } else { 'skylyrac/blocksds:slim-latest' }
$template = Get-DsTemplatePath $config $project
if (-not (Test-Path -LiteralPath $template)) { throw "Falta la plantilla de build: $template" }

# Layout: .ds-game-dev/build/<variant>/ (tree), .ds-game-dev/build/out/ (sidecars).
$buildBase = Join-Path $project '.ds-game-dev\build'
# Tree/container name and ROM suffix; the config lookup keeps using $Variant.
$treeName = $Variant
$romSuffix = if ($Variant -eq 'default') { '' } else { $Variant }
if ($NitroTrace -and $Contract) { throw '-NitroTrace y -Contract son excluyentes.' }
. (Join-Path $PSScriptRoot 'partial\partial-common.ps1')
if ($NitroTrace) { $treeName = "$Variant-trace"; $romSuffix = $treeName }
$nitroOnly = $null
if ($Contract) {
    $resolved = Resolve-PartialContract $Contract (Join-Path $project 'nitrofiles')
    $treeName = "$Variant-$($resolved.Name)"
    $romSuffix = $treeName
    $nitroOnly = @($resolved.Files)
    Write-Output "PARTIAL_CONTRACT name=$($resolved.Name) concepts=$($resolved.Concepts -join ',') files=$($nitroOnly.Count)"
}
# Partial ROMs (contract or trace) carry the nitro probe: it is copied into the build tree and fopen/open wrapped.
$probeSource = Join-Path (Join-Path $PSScriptRoot 'partial') 'nitro_probe.c'
$withProbe = [bool]($NitroTrace -or $Contract)
$buildRoot = Join-Path $buildBase $treeName
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
$ldflags = if ($withProbe) { '-Wl,--wrap=fopen -Wl,--wrap=open' } else { '' }
$cflags = ($defineList | ForEach-Object { if ($_.StartsWith('-')) { $_ } else { "-D$_" } }) -join ' '

# Native commands write to stderr on failure; under 'Stop' Windows PowerShell
# 5.1 would turn that into a terminating error before we can explain it.
$ErrorActionPreference = 'Continue'
$imageId = docker image inspect $image --format '{{.Id}}' 2>$null
if ($LASTEXITCODE -ne 0) {
    # Either the daemon is down or the image is missing: tell them apart.
    docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker no responde. Arranca Docker Desktop y repite la build.' }
    & (Join-Path $skillRoot 'scripts\load-blocksds-image.ps1')
    $imageId = docker image inspect $image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw "La imagen BlocksDS no esta cargada y no se pudo cargar desde el paquete offline." }
}
$ErrorActionPreference = 'Stop'

Write-Trace 'docker-checks'
# Incremental build: the variant tree is kept between runs so make only
# recompiles what changed. It is wiped when anything that is not tracked by
# make's dependency files changes (template, project contract, image, defines).
$templateHash = Get-ChildItem -LiteralPath $template -Recurse -File | Sort-Object FullName |
    ForEach-Object { $_.FullName.Substring($template.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
$stampText = (@("image=$imageId", "variant=$treeName", "cflags=$cflags", "ldflags=$ldflags", "probe=$(if ($withProbe) { (Get-FileHash -LiteralPath $probeSource -Algorithm SHA256).Hash } else { '' })", "nitro=$(if ($nitroOnly) { ($nitroOnly -join ',') } else { '' })",
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
$fullPush = [bool]$Clean -or ($previousStamp -ne $stampText)
$changed = New-Object System.Collections.Generic.HashSet[string]
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
    [void]$script:changed.Add($Destination)
    $script:synced++
}
# Mirror a directory: sync every file and drop files no longer in the source.
$extraKeep = @{}
function Sync-Tree([string]$Source, [string]$Destination, [string[]]$Only = $null) {
    $wanted = @{}
    if ($null -ne $Only) {
        # Partial copy: only the listed files, which must exist.
        $missing = @($Only | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Source $_) -PathType Leaf) })
        if ($missing.Count -gt 0) { throw ("Contrato: no existen en $Source -> " + ($missing -join ', ')) }
        foreach ($rel in $Only) {
            $target = Join-Path $Destination $rel.Replace('/', '\')
            $wanted[$target] = $true
            Sync-File (Join-Path $Source $rel) $target
        }
    } else {
        foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
            $target = Join-Path $Destination $file.FullName.Substring($Source.Length).TrimStart('\')
            $wanted[$target] = $true
            Sync-File $file.FullName $target
        }
    }
    if (Test-Path -LiteralPath $Destination) {
        foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File -Force) {
            if (-not $wanted.ContainsKey($file.FullName) -and -not $extraKeep.ContainsKey($file.FullName)) {
                Remove-Item -LiteralPath $file.FullName -Force
                $index.Remove($file.FullName)
                [void]$script:changed.Remove($file.FullName)
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
    if ($withProbe) {
        $probeTarget = Join-Path (Join-Path (Join-Path $buildRoot 'arm9') 'source') 'nitro_probe.c'
        $extraKeep[$probeTarget] = $true
        Sync-File $probeSource $probeTarget
    }
    foreach ($item in $config.copy) {
        $source = (Resolve-Path -LiteralPath (Join-Path $project $item.source)).Path
        $destination = Join-Path $buildRoot $item.destination
        if (Test-Path -LiteralPath $source -PathType Container) {
            if ($nitroOnly -and $item.destination -eq 'nitrofiles') { Sync-Tree $source $destination $nitroOnly }
            else { Sync-Tree $source $destination }
        }
        else { Sync-File $source $destination }
    }
    if ($config.icon) {
        Sync-File (Resolve-Path -LiteralPath (Join-Path $project $config.icon)).Path (Join-Path $buildRoot 'ds-game-icon.png')
    }
    $cfg = Get-Item -LiteralPath $configPath
    $script:inputCount++
    if ($cfg.LastWriteTimeUtc -gt $script:inputsNewest) { $script:inputsNewest = $cfg.LastWriteTimeUtc }
}

# Id of the container whose volume matches this tree (see the Docker section).
$markerPath = Join-Path $buildRoot '.ds-build-volume'
$markerAtStart = if (($Clean -or $previousStamp -ne $stampText) -or -not (Test-Path -LiteralPath $markerPath)) { '' } else { (Get-Content -Raw -LiteralPath $markerPath).Trim() }
Write-Trace 'stamp-done'
Sync-All
Write-Trace 'sync-done'
if ($removed -gt 0) {
    # A deleted source leaves its object behind and make would not relink,
    # so the ROM would keep the removed code. Deletions are rare: rebuild.
    $removedCount = $removed
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    $index = @{}
    $changed.Clear()
    $fullPush = $true
    $synced = 0
    $removed = 0
    Sync-All
    $removed = $removedCount
}
Set-Content -LiteralPath $stampPath -Value $stampText -NoNewline
$index | ConvertTo-Json -Compress | Set-Content -LiteralPath $indexPath
# The index now claims files the volume may not have yet; if this run dies
# before the push finishes, the missing marker forces a full push next time.
if ($changed.Count -gt 0 -or $fullPush) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }

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
if ($ldflags) { $env:LDFLAGS = $ldflags }

# The real build tree lives in a named Docker volume (ext4 inside the Docker
# VM): make's stat/.d traffic over the Windows bind mount was ~8 s per run.
# The Windows tree only holds the synced sources, index and stamp. Changed
# files are streamed into the volume as a tar; outputs are copied back.
$pathHash = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($project.ToLowerInvariant()))).Replace('-', '').Substring(0, 10).ToLowerInvariant()
$volName = "dsbuild-$pathHash-$treeName"
$ctrName = "dsb-$pathHash-$treeName"
$logPath = Join-Path $buildRoot 'build.log'
$logLines = New-Object System.Collections.Generic.List[string]
$makeExit = 1
$mutex = New-Object System.Threading.Mutex($false, "Global\$volName")
[void]$mutex.WaitOne()
$ErrorActionPreference = 'Continue'
$previousEncoding = [Console]::OutputEncoding
try {
    # The marker holds the id of the container that owns the volume contents.
    # Same id still present => the volume is intact (it cannot be removed while
    # the container exists). Anything else (Docker reset, pruned, first run,
    # forced rebuild, new stamp, deleted sources) => start from scratch.
    $state = (docker inspect $ctrName --format '{{.Id}} {{.State.Running}}' 2>$null)
    $ctrId = ''; $running = $false
    if ($LASTEXITCODE -eq 0 -and "$state" -match '^(\S+) (\S+)$') { $ctrId = $Matches[1]; $running = ($Matches[2] -eq 'true') }
    if (-not $ctrId -or $markerAtStart -ne $ctrId) { $fullPush = $true }
    if ($fullPush) {
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        docker rm -f $ctrName *> $null
        docker volume rm -f $volName *> $null
        docker volume create $volName *> $null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el volumen $volName" }
        # /out is the Windows variant tree: only the products are written there.
        $ctrId = (docker run -d --init --name $ctrName -v "${volName}:/source" -v "${buildRoot}:/out" -w /source $image sleep infinity 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "No se pudo arrancar el contenedor $ctrName" }
        $ctrId = "$ctrId".Trim()
    } elseif (-not $running) {
        docker start $ctrName *> $null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo arrancar el contenedor $ctrName" }
    }
    Write-Trace 'container-ready'
    # Push the changed files (all of them on a full push).
    $pushList = if ($fullPush) { @($index.Keys) } else { @($changed) }
    if ($pushList.Count -gt 0) {
        $rootLen = $buildRoot.Length
        $rel = $pushList | ForEach-Object { $_.Substring($rootLen).TrimStart('\').Replace('\', '/') }
        $listFile = Join-Path $outDir ".push-$volName.txt"
        $tarFile = Join-Path $buildRoot '.ds-push.tar'
        [IO.File]::WriteAllLines($listFile, [string[]]$rel, (New-Object System.Text.UTF8Encoding($false)))
        & "$env:SystemRoot\System32\tar.exe" -C $buildRoot -cf $tarFile -T $listFile
        if ($LASTEXITCODE -ne 0) { throw 'tar fallo al empaquetar los fuentes cambiados' }
        docker exec $ctrName tar -xf /out/.ds-push.tar -C /source --no-same-owner
        if ($LASTEXITCODE -ne 0) { throw 'no se pudieron extraer los fuentes en el volumen' }
        Remove-Item -LiteralPath $listFile, $tarFile -Force -ErrorAction SilentlyContinue
    }
    Write-Trace 'pushed'
    [IO.File]::WriteAllText($markerPath, $ctrId, (New-Object System.Text.UTF8Encoding($false)))
    $dockerArgs = @('exec', '-e', 'CFLAGS', '-e', 'LDFLAGS', '-e', 'DS_GAME_TITLE', '-e', 'DS_GAME_SUBTITLE', '-e', 'DS_GAME_AUTHOR',
        '-w', '/source', $ctrName, 'sh', '-c', ('make -j$(nproc) -Otarget' + $makeVars + ' && mkdir -p /out/build && cp -f "' + $config.outputRom + '" /out/ && cp -f build/*.elf build/*.map /out/build/'))
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    & docker @dockerArgs 2>&1 | ForEach-Object { $logLines.Add("$_") }
    $makeExit = $LASTEXITCODE
    Write-Trace 'make-done'
    Write-Trace 'outputs-copied'
} finally {
    [Console]::OutputEncoding = $previousEncoding
    $ErrorActionPreference = 'Stop'
    Remove-Item Env:\CFLAGS, Env:\LDFLAGS, Env:\DS_GAME_TITLE, Env:\DS_GAME_SUBTITLE, Env:\DS_GAME_AUTHOR -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
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

Write-Trace 'log-written'
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
    if (-not $romSuffix) { $base }
    else { Join-Path (Split-Path -Parent $base) ("{0}-{1}.nds" -f [IO.Path]::GetFileNameWithoutExtension($base), $romSuffix) }
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
    tree = $treeName
    nitroFiles = $(if ($nitroOnly) { $nitroOnly.Count } else { $null })
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
