[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    # Wildcard on the test name (python: file stem or command text; C: c/<stem>).
    [string]$Filter,
    # Lines of output shown for a failing test.
    [int]$TailLines = 25
)
# Runs project.json "hostTests" commands (cmd.exe, from the project root) and
# every tests/c/test_*.c (gcc + sanitizers inside WSL).
# Prints DS_HOST_TEST=PASS|FAIL name=.. ms=.. per test and DS_HOST_TESTS=PASS|FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'project-common.ps1')
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
$project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
$config = Get-DsProjectConfig $project
$commands = @($config.hostTests | Where-Object { $_ })
$cTests = @()
$cDir = Join-Path $project 'tests\c'
if (Test-Path -LiteralPath $cDir) { $cTests = @(Get-ChildItem -LiteralPath $cDir -Filter 'test_*.c' -File | Sort-Object Name) }

# Python tests under tests/ that no declared command mentions are probably forgotten.
$pyDir = Join-Path $project 'tests'
if (Test-Path -LiteralPath $pyDir) {
    $joined = $commands -join "`n"
    $undeclared = @(Get-ChildItem -LiteralPath $pyDir -Filter 'test_*.py' -File |
        Where-Object { $joined -notmatch [regex]::Escape($_.Name) } | ForEach-Object { $_.Name })
    if ($undeclared.Count -gt 0) { Write-Output ("DS_HOST_TESTS_WARNING=undeclared files=" + ($undeclared -join ',')) }
}
if ($commands.Count -eq 0 -and $cTests.Count -eq 0) { Write-Output 'DS_HOST_TESTS=SKIP reason=no-host-tests'; exit 0 }

$passed = 0
$failed = 0
function Show-Failure([string[]]$Lines) {
    $Lines | Where-Object { $_ -and $_ -notmatch '^System\.Management\.Automation\.RemoteException$' } |
        Select-Object -Last $TailLines | ForEach-Object { Write-Output ('  ' + $(if ($_.Length -gt 220) { $_.Substring(0, 220) } else { $_ })) }
}

Push-Location $project
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    foreach ($command in $commands) {
        $name = if ($command -match 'tests[\\/](test_[^\s"'']+?)\.py') { $Matches[1] } else { $command }
        if ($Filter -and $name -notlike $Filter -and $command -notlike $Filter) { continue }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ErrorActionPreference = 'Continue'
        $lines = @(& cmd.exe /d /s /c "`"$command`"" 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $sw.Stop()
        $ms = [int]$sw.ElapsedMilliseconds
        if ($code -eq 0) { $passed++; Write-Output "DS_HOST_TEST=PASS name=$name ms=$ms" }
        else { $failed++; Write-Output "DS_HOST_TEST=FAIL name=$name ms=$ms exit=$code"; Show-Failure $lines }
    }

    if ($cTests.Count -gt 0) {
        $outDir = Join-Path $project '.ds-game-dev\build\host-tests'
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $cmdName = $null
        $includeDir = Join-Path $project 'include'
        $skillInclude = Join-Path $root 'templates\host-test'
        foreach ($test in $cTests) {
            $name = "c/" + $test.BaseName
            if ($Filter -and $name -notlike $Filter -and $test.BaseName -notlike $Filter) { continue }
            if (-not $cmdName) { Start-DsWslKeepAlive; $cmdName = 'wsl' }
            $sources = @()
            foreach ($l in (Get-Content -LiteralPath $test.FullName -TotalCount 30)) {
                if ($l -match '^\s*//\s*DS_TEST_SOURCES:\s*(.*)$') { $sources += ($Matches[1].Trim() -split '\s+' | Where-Object { $_ }) }
            }
            $srcWsl = @($sources | ForEach-Object { ConvertTo-DsWslPath (Join-Path $project $_) })
            $exe = Join-Path $outDir $test.BaseName
            $sh = Join-Path $outDir ("run-" + $test.BaseName + ".sh")
            $gccParts = @('gcc', '-std=gnu11', '-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                "-I'$(ConvertTo-DsWslPath $includeDir)'", "-I'$(ConvertTo-DsWslPath $cDir)'", "-I'$(ConvertTo-DsWslPath $skillInclude)'",
                '-DDS_HOST_TEST', "'$(ConvertTo-DsWslPath $test.FullName)'") + ($srcWsl | ForEach-Object { "'$_'" }) +
                @('-o', "'$((ConvertTo-DsWslPath $outDir) + '/' + $test.BaseName)'", '-lm')
            $script = "cd '$(ConvertTo-DsWslPath $project)'`n" + ($gccParts -join ' ') + " || exit 97`n" +
                "export ASAN_OPTIONS=detect_leaks=0:abort_on_error=0 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`n" +
                "'$((ConvertTo-DsWslPath $outDir) + '/' + $test.BaseName)'`n"
            [IO.File]::WriteAllText($sh, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ErrorActionPreference = 'Continue'
            $lines = @(& wsl.exe bash (ConvertTo-DsWslPath $sh) 2>&1 | Where-Object { "$_" -notmatch '^wsl: ' } | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $sw.Stop()
            $ms = [int]$sw.ElapsedMilliseconds
            if ($code -eq 0) { $passed++; Write-Output "DS_HOST_TEST=PASS name=$name ms=$ms" }
            else {
                $failed++
                $why = if ($code -eq 97) { ' stage=compile' } else { '' }
                Write-Output "DS_HOST_TEST=FAIL name=$name ms=$ms exit=$code$why"
                Show-Failure $lines
            }
        }
    }
} finally {
    [Console]::OutputEncoding = $previousEncoding
    Pop-Location
}
$state = if ($failed -eq 0) { 'PASS' } else { 'FAIL' }
Write-Output "DS_HOST_TESTS=$state passed=$passed failed=$failed"
if ($failed -gt 0) { exit 1 }
