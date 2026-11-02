[CmdletBinding()]
param([Parameter(Mandatory)][string]$RomPath, [int]$Port = 24710, [string]$BreakpointAddress = '0x02000804')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$agent = Join-Path $root 'runtime\bin\desmume-agent'
if (-not (Test-Path -LiteralPath $agent)) { throw "Falta el runtime DeSmuME: $agent" }
if (-not (Test-Path -LiteralPath $RomPath)) { throw "Falta la ROM: $RomPath" }
function WslPath([string]$path) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    return "/mnt/$($resolved.Substring(0,1).ToLowerInvariant())$($resolved.Substring(2).Replace('\','/'))"
}
$outPath = Join-Path $env:TEMP "ds-game-dev-gdb-$Port.out"
$errPath = Join-Path $env:TEMP "ds-game-dev-gdb-$Port.err"
Remove-Item -LiteralPath $outPath,$errPath -Force -ErrorAction SilentlyContinue
$process = Start-Process wsl.exe -ArgumentList @((WslPath $agent), '--rom', (WslPath $RomPath), '--frames', '100000', '--arm9-gdb', "$Port") -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru -WindowStyle Hidden
try {
    $gdbCmd = "gdb-multiarch -q -nx -batch -ex 'set pagination off' -ex 'set architecture arm' -ex 'target remote :$Port' -ex 'info registers r0 r13 r15 cpsr' -ex 'break *$BreakpointAddress' -ex 'continue' -ex 'info registers pc' 2>/dev/null"
    $gdbOutput = & wsl bash -c $gdbCmd | Out-String
    Write-Output $gdbOutput.TrimEnd()
    if ($gdbOutput -notmatch 'Breakpoint 1' -or $gdbOutput -notmatch 'pc\s+0x') { throw 'GDB no consiguió leer registros y alcanzar el breakpoint esperado.' }
    Write-Output "DSM_GDB_RESULT=PASS rom=$RomPath breakpoint=$BreakpointAddress"
} finally {
    if ($process -and -not $process.HasExited) { $process.Kill() }
    if ($process) { Wait-Process -Id $process.Id -ErrorAction SilentlyContinue }
}
