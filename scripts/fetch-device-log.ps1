[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    # Absolute path on the DS SD card, e.g. /mygame_perf.log
    [Parameter(Mandatory)] [string]$RemoteFile,
    [string]$OutDir,
    [switch]$Delete,
    [string]$HostName,
    [int]$Port,
    [string]$User,
    [string]$Password
)

# Downloads a log the ROM wrote to the SD card (profiling, crash reports) over
# the same FTP server used by upload-rom.ps1. Reading is safe; -Delete removes
# the remote file afterwards and needs the user's go-ahead.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ftp-common.ps1')

$overrides = @{}
$paramMap = @{ HostName = 'host'; Port = 'port'; User = 'user'; Password = 'password' }
foreach ($name in $paramMap.Keys) { if ($PSBoundParameters.ContainsKey($name)) { $overrides[$paramMap[$name]] = $PSBoundParameters[$name] } }
$ftp = Get-DsFtpSettings -ProjectPath $ProjectPath -Overrides $overrides

if (-not $RemoteFile.StartsWith('/')) { $RemoteFile = "/$RemoteFile" }
if (-not $OutDir) { $OutDir = Join-Path $ProjectPath 'artifacts\device-logs' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$leaf = [IO.Path]::GetFileNameWithoutExtension($RemoteFile)
$ext = [IO.Path]::GetExtension($RemoteFile)
$out = Join-Path $OutDir ("{0}-{1}{2}" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'), $ext)

$curl = Get-Command curl.exe -ErrorAction Stop
$url = "$(Get-DsFtpBase $ftp)$RemoteFile"
$auth = "$($ftp.user):$($ftp.password)"
Assert-DsFtpReachable -Settings $ftp

$curlArgs = @('--connect-timeout', '8', '--max-time', '60', '--fail', '--silent', '--show-error', '--ftp-pasv', '--user', $auth, '-o', $out, $url)
if ($Delete) { $curlArgs = @('-Q', "-DELE $RemoteFile") + $curlArgs }
$ErrorActionPreference = 'Continue'
& $curl.Source @curlArgs 2>&1 | ForEach-Object { "$_" }
$exit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($exit -eq 78) { throw "DEVICE_LOG_MISSING remote=$RemoteFile. La ROM no escribió ese archivo: comprueba que se compiló con el log activado y que el usuario jugó con esa ROM." }
if ($exit -ne 0) { throw "FTP falló (curl exit $exit) leyendo $url." }

$size = (Get-Item -LiteralPath $out).Length
Write-Output "DEVICE_LOG_RESULT=PASS remote=$RemoteFile local=$out size=$size deleted=$([bool]$Delete)"
exit 0
