# Parallel scenario execution (dot-sourced after wsl-common.ps1).

# Groups scenario files so that a scenario with "start_state" X always shares a
# group (and follows) the scenarios that "save_state" X. Returns an array of
# arrays of FileInfo, each in a safe execution order.
function Get-DsScenarioGroups {
    param([Parameter(Mandatory)] [object[]]$Files)
    $info = @()
    foreach ($f in $Files) {
        $txt = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction SilentlyContinue
        $saves = @(); $start = $null
        if ($txt) {
            $saves = @([regex]::Matches($txt, '"save_state"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            $m = [regex]::Match($txt, '"start_state"\s*:\s*"([^"]+)"')
            if ($m.Success) { $start = $m.Groups[1].Value }
        }
        $info += [pscustomobject]@{ File = $f; Saves = $saves; Start = $start; Group = $info.Count }
    }
    foreach ($i in $info) {
        if (-not $i.Start) { continue }
        foreach ($j in $info) {
            if ($j.Saves -contains $i.Start -and $j.Group -ne $i.Group) {
                $old = $j.Group
                foreach ($k in $info) { if ($k.Group -eq $old) { $k.Group = $i.Group } }
            }
        }
    }
    $groups = @()
    foreach ($g in ($info | Group-Object Group)) {
        $pending = New-Object System.Collections.Generic.List[object]
        $g.Group | ForEach-Object { $pending.Add($_) }
        $producedHere = @($g.Group | ForEach-Object { $_.Saves })
        $done = @(); $ordered = @()
        while ($pending.Count -gt 0) {
            $pick = $null
            foreach ($p in $pending) {
                if (-not $p.Start -or ($producedHere -notcontains $p.Start) -or ($done -contains $p.Start)) { $pick = $p; break }
            }
            if (-not $pick) { $pick = $pending[0] }
            [void]$pending.Remove($pick)
            $ordered += $pick.File
            $done += $pick.Saves
        }
        $groups += ,@($ordered)
    }
    return $groups
}

# Runs scenarios in $Parallel simultaneous WSL runner processes (one emulator
# each). Each worker writes to <OutputPath>\_wN; afterwards the per-scenario
# dirs are moved to <OutputPath>\<stem> and a merged suite.json is written, so
# the layout equals a single multi-scenario run. Prints DSM_ lines plus one
# aggregated DSM_SUITE_RESULT. Returns the worst exit code.
function Invoke-DsRunnerParallel {
    param(
        [Parameter(Mandatory)] [string]$SkillRoot,
        [Parameter(Mandatory)] [string]$RomPath,
        [Parameter(Mandatory)] [object[]]$Files,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [int]$Parallel,
        [string]$MapPath,
        [string]$StatesDir,
        [switch]$Jit,
        [switch]$NoSkipRender
    )
    $runner = Join-Path $SkillRoot 'runtime\run_scenario.py'
    $library = Join-Path $SkillRoot 'runtime\bin\libdesmume.so'
    foreach ($path in (@($RomPath, $runner, $library) + @($Files | ForEach-Object { $_.FullName }))) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Ruta no encontrada: $path" }
    }
    Start-DsWslKeepAlive
    $started = [Diagnostics.Stopwatch]::StartNew()
    # "suite": false scenarios are skipped in multi-scenario runs; the runner only does it
    # when it sees several files, which a worker may not, so it is done here.
    $skipped = @(); $run = @()
    foreach ($f in $Files) {
        $isOut = $false
        try { $isOut = ((Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json).suite -eq $false) } catch { }
        if ($isOut -and $Files.Count -gt 1) { $skipped += $f.BaseName } else { $run += $f }
    }
    $groups = @(Get-DsScenarioGroups -Files $run)
    $n = [Math]::Max(1, [Math]::Min($Parallel, $groups.Count))
    $buckets = @(1..$n | ForEach-Object { [pscustomobject]@{ Files = @(); Load = 0 } })
    foreach ($g in ($groups | Sort-Object { -$_.Count })) {
        $b = $buckets | Sort-Object Load | Select-Object -First 1
        $b.Files += @($g); $b.Load += $g.Count
    }
    $buckets = @($buckets | Where-Object { $_.Files.Count -gt 0 })
    if (-not $StatesDir) { $StatesDir = Join-Path $OutputPath '_states' }
    New-Item -ItemType Directory -Force -Path $StatesDir | Out-Null
    $procs = @(); $i = 0
    foreach ($b in $buckets) {
        $i++
        $wout = Join-Path $OutputPath "_w$i"
        New-Item -ItemType Directory -Force -Path $wout | Out-Null
        $a = @('python3', '-u', (ConvertTo-DsWslPath $runner), '--rom', (ConvertTo-DsWslPath $RomPath),
            '--lib', (ConvertTo-DsWslPath $library), '--out', (ConvertTo-DsWslPath $wout),
            '--states-dir', (ConvertTo-DsWslPath $StatesDir))
        if ($MapPath) { $a += @('--map', (ConvertTo-DsWslPath $MapPath)) }
        if ($NoSkipRender) { $a += '--no-skip-render' }
        if ($Jit) { $a += '--jit' }
        foreach ($s in $b.Files) { $a += (ConvertTo-DsWslPath $s.FullName) }
        $argString = ($a | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $argString -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $wout 'stdout.txt') -RedirectStandardError (Join-Path $wout 'stderr.txt')
        $procs += [pscustomobject]@{ Proc = $p; Out = $wout; Files = $b.Files }
    }
    $worst = 0
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($w in $procs) {
        $w.Proc.WaitForExit()
        $code = $w.Proc.ExitCode
        $lines = @(Get-Content -LiteralPath (Join-Path $w.Out 'stdout.txt') -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($l in $lines) {
            if (-not $l.StartsWith('DSM_') -or $l.StartsWith('DSM_SUITE_RESULT')) { continue }
            Write-Host $l
            if ($l -match '^DSM_SCENARIO_RESULT=(\S+) name=(\S+) frames=(\d+) wall_ms=(\d+)') {
                $results.Add([pscustomobject]@{ Status = $Matches[1]; Name = $Matches[2]; Frames = [int]$Matches[3]; Wall = [int]$Matches[4] })
            }
        }
        if ($code -gt $worst) { $worst = $code }
        # Move scenario outputs up so the layout matches a single-process run.
        if ($w.Files.Count -eq 1) {
            $dest = Join-Path $OutputPath $w.Files[0].BaseName
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Get-ChildItem -LiteralPath $w.Out -Force | Where-Object { $_.Name -notin 'stdout.txt', 'stderr.txt' } |
                ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dest -Force }
        } else {
            Get-ChildItem -LiteralPath $w.Out -Directory -Force | Where-Object { $_.Name -ne '_states' } |
                ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputPath $_.Name) -Force }
        }
    }
    $wall = [int]$started.Elapsed.TotalMilliseconds
    $pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
    $fail = @($results | Where-Object { $_.Status -in 'FAIL', 'NO_ASSERTIONS' }).Count
    $err = @($results | Where-Object { $_.Status -eq 'ERROR' }).Count
    # Scenarios that never reported (worker died) count as errors.
    $missing = $run.Count - $results.Count
    if ($missing -gt 0) { $err += $missing; if ($worst -lt 2) { $worst = 2 } }
    $status = if ($worst -ge 2 -or $err -gt 0) { 'ERROR' } elseif ($worst -eq 1 -or $fail -gt 0) { 'FAIL' } else { 'PASS' }
    $total = $results.Count + [Math]::Max(0, $missing)
    Write-Host "DSM_SUITE_RESULT=$status total=$total pass=$pass fail=$fail error=$err wall_ms=$wall"
    $suite = [ordered]@{
        status = $status; total = $total; pass = $pass; fail = $fail; error = $err; wall_ms = $wall; skipped = $skipped
        scenarios = @($results | ForEach-Object { [ordered]@{ name = $_.Name; status = $_.Status; frames = $_.Frames; wall_ms = $_.Wall; dir = $_.Name } })
    }
    [IO.File]::WriteAllText((Join-Path $OutputPath 'suite.json'), ($suite | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $log = New-Object System.Collections.Generic.List[string]
    foreach ($w in $procs) {
        foreach ($f in 'stdout.txt', 'stderr.txt') {
            $fp = Join-Path $w.Out $f
            if (Test-Path -LiteralPath $fp) { Get-Content -LiteralPath $fp -Encoding UTF8 | ForEach-Object { $log.Add($_) } }
        }
        Remove-Item -LiteralPath $w.Out -Recurse -Force -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllLines((Join-Path $OutputPath 'emulator.log'), $log, (New-Object Text.UTF8Encoding($false)))
    return $worst
}
