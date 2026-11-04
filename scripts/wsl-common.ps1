# WSL helpers (dot-sourced): path conversion, a keep-alive so the WSL VM
# stays warm between emulator runs (a cold first call costs ~30 s), and the
# headless scenario runner invocation.

$script:DsWslPathCache = @{}

function ConvertTo-DsWslPath {
    param([Parameter(Mandatory)] [string]$Path)
    # Paths that do not exist yet (outputs) are converted by rule.
    $exists = Test-Path -LiteralPath $Path
    $resolved = if ($exists) { (Resolve-Path -LiteralPath $Path).Path } else { [IO.Path]::GetFullPath($Path) }
    if ($script:DsWslPathCache.ContainsKey($resolved)) { return $script:DsWslPathCache[$resolved] }
    $converted = $null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not $exists) { throw 'skip wslpath' }
        $out = & wsl.exe wslpath -a ($resolved.Replace('\', '/')) 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { $converted = ("$out").Trim() }
    } catch { } finally { $ErrorActionPreference = $previous }
    if (-not $converted -or -not $converted.StartsWith('/')) {
        $converted = "/mnt/$($resolved.Substring(0,1).ToLowerInvariant())$($resolved.Substring(2).Replace('\','/'))"
    }
    $script:DsWslPathCache[$resolved] = $converted
    return $converted
}

function Start-DsWslKeepAlive {
    $pidFile = Join-Path $env:TEMP 'ds-game-dev-wsl-keepalive.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $old = 0
        [void][int]::TryParse(((Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue) -join '').Trim(), [ref]$old)
        if ($old -gt 0 -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { return }
    }
    try {
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-e', 'sleep', '1800') -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $pidFile -Value $p.Id
    } catch { }
}

# Runs the headless scenario runner inside WSL. Streams only DSM_ lines to the
# console and writes the full raw output to $LogPath as UTF-8 (never
# Tee-Object: it writes UTF-16 in Windows PowerShell 5.1). Returns the worst
# exit code (0 pass, 1 fail, 2 error).
function Invoke-DsRunner {
    param(
        [Parameter(Mandatory)] [string]$SkillRoot,
        [Parameter(Mandatory)] [string]$RomPath,
        [Parameter(Mandatory)] [string[]]$ScenarioPaths,
        [Parameter(Mandatory)] [string]$OutputPath,
        [string]$MapPath,
        [string]$StatesDir,
        [switch]$Jit,
        [switch]$NoSkipRender,
        [string]$LogPath
    )
    $runner = Join-Path $SkillRoot 'runtime\run_scenario.py'
    $library = Join-Path $SkillRoot 'runtime\bin\libdesmume.so'
    foreach ($path in (@($RomPath, $runner, $library) + $ScenarioPaths)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Ruta no encontrada: $path" }
    }
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    if (-not $LogPath) { $LogPath = Join-Path $OutputPath 'emulator.log' }
    Start-DsWslKeepAlive
    $newCli = [bool](Select-String -LiteralPath $runner -Pattern '--rom' -SimpleMatch -Quiet)
    $runs = @()
    if ($newCli) {
        $a = @('python3', '-u', (ConvertTo-DsWslPath $runner), '--rom', (ConvertTo-DsWslPath $RomPath),
            '--lib', (ConvertTo-DsWslPath $library), '--out', (ConvertTo-DsWslPath $OutputPath))
        if ($MapPath) { $a += @('--map', (ConvertTo-DsWslPath $MapPath)) }
        if ($StatesDir) {
            New-Item -ItemType Directory -Force -Path $StatesDir | Out-Null
            $a += @('--states-dir', (ConvertTo-DsWslPath $StatesDir))
        }
        if ($NoSkipRender) { $a += '--no-skip-render' }
        if ($Jit) { $a += '--jit' }
        foreach ($s in $ScenarioPaths) { $a += (ConvertTo-DsWslPath $s) }
        $runs += ,$a
    } else {
        # Legacy runner: positional ROM SCENARIO OUT LIB [MAP], one scenario per process.
        foreach ($s in $ScenarioPaths) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($s)
            $out = if ($ScenarioPaths.Count -gt 1) { Join-Path $OutputPath $stem } else { $OutputPath }
            New-Item -ItemType Directory -Force -Path $out | Out-Null
            $a = @('python3', '-u', (ConvertTo-DsWslPath $runner), (ConvertTo-DsWslPath $RomPath), (ConvertTo-DsWslPath $s),
                (ConvertTo-DsWslPath $out), (ConvertTo-DsWslPath $library))
            if ($MapPath) { $a += (ConvertTo-DsWslPath $MapPath) }
            $runs += ,$a
        }
    }
    $log = New-Object System.Collections.Generic.List[string]
    $worst = 0
    $previousPreference = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        foreach ($a in $runs) {
            & wsl.exe @a 2>&1 | ForEach-Object {
                $line = "$_"
                $log.Add($line)
                if ($line.StartsWith('DSM_')) { Write-Host $line }
            }
            if ($LASTEXITCODE -gt $worst) { $worst = $LASTEXITCODE }
        }
    } finally {
        $ErrorActionPreference = $previousPreference
        [Console]::OutputEncoding = $previousEncoding
    }
    [IO.File]::WriteAllLines($LogPath, $log, (New-Object System.Text.UTF8Encoding($false)))
    return $worst
}
