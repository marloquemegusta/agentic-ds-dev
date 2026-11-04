[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RomPath,
    [string]$ProjectPath,
    # Defaults to the elf recorded in the ROM's buildinfo (build-project.ps1).
    [string]$ElfPath,
    [int]$Port = 24710,
    # Symbol or *address. A symbol needs the ELF.
    [string]$Breakpoint = 'main',
    [int]$Frames = 20000,
    [int]$TimeoutSeconds = 90
)
# Prints the breakpoint hit, a backtrace, pc and DSM_GDB_RESULT=PASS|FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
. (Join-Path $PSScriptRoot 'project-common.ps1')
$agent = Join-Path $root 'runtime\bin\desmume-agent'
if (-not (Test-Path -LiteralPath $agent)) { throw "Falta el runtime DeSmuME: $agent" }
if (-not (Test-Path -LiteralPath $RomPath)) { throw "Falta la ROM: $RomPath" }
$rom = (Resolve-Path -LiteralPath $RomPath).Path

if (-not $ElfPath) {
    $project = if ($ProjectPath) { (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\') } else { $null }
    if (-not $project) {
        # Assume the ROM sits at the project root (where build-project.ps1 puts it).
        $candidate = Split-Path -Parent $rom
        if (Test-Path -LiteralPath (Join-Path $candidate '.ds-game-dev')) { $project = $candidate }
    }
    if ($project) {
        $infoPath = Get-DsBuildInfoPath $project $rom
        if (Test-Path -LiteralPath $infoPath) {
            $elf = (Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json).elf
            if ($elf -and (Test-Path -LiteralPath $elf)) { $ElfPath = $elf }
        }
    }
}
if (-not $ElfPath -and -not $Breakpoint.StartsWith('*')) {
    Write-Output 'DSM_GDB_RESULT=FAIL reason=no-elf (pasa -ElfPath/-ProjectPath o usa -Breakpoint *0xADDR)'
    exit 1
}

Start-DsWslKeepAlive
$romWsl = ConvertTo-DsWslPath $rom
$agentWsl = ConvertTo-DsWslPath $agent
$outPath = Join-Path $env:TEMP "ds-game-dev-gdb-$Port.out"
$errPath = Join-Path $env:TEMP "ds-game-dev-gdb-$Port.err"
Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
$process = Start-Process wsl.exe -ArgumentList @('timeout', ($TimeoutSeconds + 15), $agentWsl, '--rom', $romWsl, '--frames', $Frames, '--arm9-gdb', $Port) `
    -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru -WindowStyle Hidden
$result = 'FAIL'
try {
    $gdbArgs = @('timeout', $TimeoutSeconds, 'gdb-multiarch', '-q', '-nx', '-batch', '-ex', 'set pagination off', '-ex', 'set architecture arm')
    if ($ElfPath) { $gdbArgs += @('-ex', ('file ' + (ConvertTo-DsWslPath $ElfPath))) }
    $gdbArgs += @('-ex', "target remote :$Port", '-ex', "break $Breakpoint", '-ex', 'continue', '-ex', 'bt 8', '-ex', 'info registers pc')
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& wsl.exe @gdbArgs 2>$null | ForEach-Object { "$_" })
    } finally { $ErrorActionPreference = $previous }
    $text = $lines -join "`n"
    # Keep the signal only: breakpoint hit, backtrace frames, pc.
    $lines | Where-Object { $_ -match '^(Breakpoint \d|#\d|pc\s)' } | ForEach-Object { Write-Output $_ }
    if ($text -match 'Breakpoint 1,' -and $text -match '(?m)^#0' -and $text -match '(?m)^pc\s+0x') { $result = 'PASS' }
    elseif ($text -match 'pc\s+0x') { Write-Output 'DSM_GDB_NOTE=breakpoint-not-hit' }
    else { $lines | Select-Object -Last 5 | ForEach-Object { Write-Output $_ } }
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill() }
    # The Linux agent outlives the wsl.exe wrapper: kill it by its port.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & wsl.exe pkill -f "arm9-gdb $Port" 2>$null | Out-Null
    $ErrorActionPreference = $previous
}
Write-Output "DSM_GDB_RESULT=$result rom=$rom breakpoint=$Breakpoint"
if ($result -ne 'PASS') { exit 1 }
