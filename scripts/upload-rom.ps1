[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$RomPath,
    [switch]$ConfirmUpload,
    [string]$HostName = '192.168.1.151',
    [int]$Port = 5000,
    [string]$RemoteDirectory = '/roms/nds',
    [string]$RemoteName = 'game.nds',
    [string]$User = 'anonymous',
    [string]$Password = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmUpload) { throw 'La subida requiere -ConfirmUpload y confirmación explícita del usuario.' }
$rom = (Resolve-Path -LiteralPath $RomPath).Path
$curl = Get-Command curl.exe -ErrorAction Stop
$base = "ftp://$HostName`:$Port$RemoteDirectory"
$remote = "$base/$RemoteName"
Write-Host "Subiendo $rom a $remote"
& $curl.Source --connect-timeout 8 --max-time 60 --fail --show-error --ftp-pasv --user "$User`:$Password" --upload-file $rom $remote
if ($LASTEXITCODE -ne 0) { throw "FTP falló. Valida IP=$HostName, puerto=$Port y que la DS esté disponible." }
$listing = & $curl.Source --connect-timeout 8 --max-time 20 --fail --silent --show-error --ftp-pasv --user "$User`:$Password" "$base/"
if ($LASTEXITCODE -ne 0 -or $listing -notmatch "(?m)$([regex]::Escape($RemoteName))\s*$") {
    throw "La subida no pudo verificarse. Valida IP=$HostName, puerto=$Port, ruta=$RemoteDirectory y nombre=$RemoteName."
}
Write-Output "FTP_UPLOAD_RESULT=PASS remote=$remote"
