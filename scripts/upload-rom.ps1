[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$RomPath,
    [switch]$ConfirmUpload,
    # Runs the ROM checks (sha, stale, variant) and stops before touching the network.
    [switch]$DryRun,
    [string]$HostName,
    [int]$Port,
    [string]$RemoteDirectory,
    # Defaults to romUploadName from the project's .ds-game-dev/project.json.
    [string]$RemoteName,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
# Terse failure: one line, no PowerShell stack trace (every line costs the caller tokens).
function Stop-Ds([string]$Message) { Write-Output $Message; exit 1 }
if (-not $ConfirmUpload -and -not $DryRun) { throw 'La subida requiere -ConfirmUpload y confirmacion explicita del usuario.' }
. (Join-Path $PSScriptRoot 'ftp-common.ps1')
. (Join-Path $PSScriptRoot 'project-common.ps1')

$overrides = @{}
$paramMap = @{ HostName = 'host'; Port = 'port'; RemoteDirectory = 'remoteDirectory'; RemoteName = 'remoteName'; User = 'user'; Password = 'password' }
foreach ($name in $paramMap.Keys) { if ($PSBoundParameters.ContainsKey($name)) { $overrides[$paramMap[$name]] = $PSBoundParameters[$name] } }
$ftp = Get-DsFtpSettings -ProjectPath $ProjectPath -Overrides $overrides

$rom = (Resolve-Path -LiteralPath $RomPath).Path
$romItem = Get-Item -LiteralPath $rom
$localSize = $romItem.Length
$romAge = [int]((Get-Date) - $romItem.LastWriteTime).TotalMinutes
$base = "$(Get-DsFtpBase $ftp)$($ftp.remoteDirectory)"
$remote = "$base/$($ftp.remoteName)"

# A stale ROM or one from another checkout is the usual reason the user sees
# "the DS doesn't have my changes"; refuse before touching the network.
$projectFull = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
if (-not $rom.StartsWith("$projectFull\", [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "La ROM no esta dentro de ${projectFull}: comprueba que es la del worktree en el que trabajas."
}
$config = Get-DsProjectConfig $projectFull
$variant = 'unknown'
$infoPath = Get-DsBuildInfoPath $projectFull $rom
if (Test-Path -LiteralPath $infoPath) {
    $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
    $variant = "$($info.variant)"
    $sha = (Get-FileHash -LiteralPath $rom -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne "$($info.romSha256)".ToLowerInvariant()) {
        Stop-Ds "ROM_UNKNOWN: $rom no coincide con la ROM registrada por build-project.ps1 (sha distinto). Recompila antes de subir."
    }
    $template = Get-DsTemplatePath $config $projectFull
    $newest = $null
    foreach ($f in (Get-DsInputFiles $config $projectFull $template)) {
        if ($null -eq $newest -or $f.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc) { $newest = $f }
    }
    $recorded = [DateTime]::Parse($info.inputsNewestUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    if ($newest -and $newest.LastWriteTimeUtc -gt $recorded) {
        Stop-Ds "ROM_STALE: $($newest.FullName) es mas reciente que la ultima build. Recompila con build-project.ps1 antes de subir."
    }
} else {
    Write-Warning 'Sin buildinfo para esta ROM (no la produjo build-project.ps1): comprobacion de frescura limitada.'
    $newestCopy = $null
    foreach ($item in @($config.copy)) {
        if (-not $item) { continue }
        $src = Join-Path $projectFull $item.source
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $cands = if (Test-Path -LiteralPath $src -PathType Container) { Get-ChildItem -LiteralPath $src -Recurse -File -Force } else { Get-Item -LiteralPath $src }
        foreach ($c in $cands) { if ($null -eq $newestCopy -or $c.LastWriteTime -gt $newestCopy.LastWriteTime) { $newestCopy = $c } }
    }
    if ($newestCopy -and $newestCopy.LastWriteTime -gt $romItem.LastWriteTime) {
        Stop-Ds "ROM_STALE: $($newestCopy.FullName) es mas reciente que $rom. Recompila con build-project.ps1 antes de subir."
    }
}
if ($variant -ne 'default') {
    Write-Warning "ROM de variante '$variant' (perf/debug), no la de produccion: avisa al usuario de que es esa."
}

if ($DryRun) {
    Write-Output "FTP_UPLOAD_RESULT=DRYRUN remote=$remote size=$localSize age_min=$romAge variant=$variant checks=OK"
    exit 0
}

try { Assert-DsFtpReachable -Settings $ftp } catch { Stop-Ds $_.Exception.Message }
$curl = Get-Command curl.exe -ErrorAction Stop
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

if ($uploadExit -ne 0) { Stop-Ds "FTP fallo (curl exit $uploadExit) subiendo a $remote. Si es un timeout (28), la DS probablemente cerro ftpd.nds: pide al usuario que lo abra." }
$remoteSize = if (($head -join "`n") -match '(?im)^Content-Length:\s*(\d+)') { [long]$Matches[1] } else { -1 }
if ($headExit -ne 0 -or $remoteSize -ne $localSize) {
    Stop-Ds "La subida no pudo verificarse: tamano remoto $remoteSize frente a local $localSize en $remote."
}

# Report which build went up, so the user can tell it apart from older ROMs.
$romDir = Split-Path -Parent $rom
$ErrorActionPreference = 'Continue'
$commit = (& git -C $romDir rev-parse --short HEAD 2>$null)
$branch = (& git -C $romDir rev-parse --abbrev-ref HEAD 2>$null)
$dirty = (& git -C $romDir status --porcelain --untracked-files=no 2>$null | Measure-Object).Count
$ErrorActionPreference = 'Stop'
$state = if (-not $commit) { 'sin git' } elseif ($dirty -gt 0) { "$dirty-cambios-sin-commit" } else { 'limpio' }

Write-Output "FTP_UPLOAD_RESULT=PASS remote=$remote size=$remoteSize age_min=$romAge variant=$variant branch=$branch commit=$commit tree=$state"
exit 0
