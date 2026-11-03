[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$RomPath,
    [switch]$ConfirmUpload,
    [string]$HostName,
    [int]$Port,
    [string]$RemoteDirectory,
    # Defaults to romUploadName from the project's .ds-game-dev/project.json.
    [string]$RemoteName,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmUpload) { throw 'La subida requiere -ConfirmUpload y confirmación explícita del usuario.' }
. (Join-Path $PSScriptRoot 'ftp-common.ps1')

$overrides = @{}
$paramMap = @{ HostName = 'host'; Port = 'port'; RemoteDirectory = 'remoteDirectory'; RemoteName = 'remoteName'; User = 'user'; Password = 'password' }
foreach ($name in $paramMap.Keys) { if ($PSBoundParameters.ContainsKey($name)) { $overrides[$paramMap[$name]] = $PSBoundParameters[$name] } }
$ftp = Get-DsFtpSettings -ProjectPath $ProjectPath -Overrides $overrides

$rom = (Resolve-Path -LiteralPath $RomPath).Path
$romItem = Get-Item -LiteralPath $rom
$localSize = $romItem.Length
$romAge = [int]((Get-Date) - $romItem.LastWriteTime).TotalMinutes
$curl = Get-Command curl.exe -ErrorAction Stop
$base = "$(Get-DsFtpBase $ftp)$($ftp.remoteDirectory)"
$remote = "$base/$($ftp.remoteName)"

# A stale ROM or one from another checkout is the usual reason the user sees
# "the DS doesn't have my changes"; refuse unless the caller insists by name.
$projectFull = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
if (-not $rom.StartsWith("$projectFull\", [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "La ROM no está dentro de ${projectFull}: comprueba que es la del worktree en el que trabajas."
}
$newest = Get-ChildItem -LiteralPath $projectFull -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.c', '.h', '.s', '.cpp' -and $_.FullName.Substring($projectFull.Length) -notmatch '^\\(\.ds-game-dev|\.worktrees|artifacts|graphify-out)\\' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest -and $newest.LastWriteTime -gt $romItem.LastWriteTime) {
    throw "ROM_STALE: $($newest.FullName) es más reciente que $rom. Recompila con build-project.ps1 antes de subir."
}

Assert-DsFtpReachable -Settings $ftp
Write-Host "Subiendo $rom ($localSize bytes, compilada hace $romAge min) a $remote"

# Windows PowerShell 5.1 turns any stderr line of a native command into a
# terminating NativeCommandError under 'Stop', even on success; curl's result
# is judged by its exit code instead, and --silent drops the progress meter.
$auth = "$($ftp.user):$($ftp.password)"
$ErrorActionPreference = 'Continue'
& $curl.Source --connect-timeout 8 --max-time 90 --fail --silent --show-error --ftp-pasv --user $auth --upload-file $rom $remote 2>&1 | ForEach-Object { "$_" }
$uploadExit = $LASTEXITCODE
$head = if ($uploadExit -eq 0) { & $curl.Source --connect-timeout 8 --max-time 20 --fail --silent --show-error --ftp-pasv --user $auth --head $remote 2>&1 | ForEach-Object { "$_" } }
$headExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

if ($uploadExit -ne 0) { throw "FTP falló (curl exit $uploadExit) subiendo a $remote. Si es un timeout (28), la DS probablemente cerró ftpd.nds: pide al usuario que lo abra." }
$remoteSize = if (($head -join "`n") -match '(?im)^Content-Length:\s*(\d+)') { [long]$Matches[1] } else { -1 }
if ($headExit -ne 0 -or $remoteSize -ne $localSize) {
    throw "La subida no pudo verificarse: tamaño remoto $remoteSize frente a local $localSize en $remote."
}

# Report which build went up, so the user can tell it apart from older ROMs.
$romDir = Split-Path -Parent $rom
$ErrorActionPreference = 'Continue'
$commit = (& git -C $romDir rev-parse --short HEAD 2>$null)
$branch = (& git -C $romDir rev-parse --abbrev-ref HEAD 2>$null)
$dirty = (& git -C $romDir status --porcelain --untracked-files=no 2>$null | Measure-Object).Count
$ErrorActionPreference = 'Stop'
$state = if (-not $commit) { 'sin git' } elseif ($dirty -gt 0) { "$dirty-cambios-sin-commit" } else { 'limpio' }

Write-Output "FTP_UPLOAD_RESULT=PASS remote=$remote size=$remoteSize age_min=$romAge branch=$branch commit=$commit tree=$state"
exit 0
