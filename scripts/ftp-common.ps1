# Shared FTP settings for upload-rom.ps1 and fetch-device-log.ps1 (dot-sourced).
#
# Precedence, lowest to highest:
#   built-in defaults < skill config/ftp.json < project .ds-game-dev/project.json
#   (romUploadName) < project .ds-game-dev/ftp.local.json (gitignored) < explicit
#   script parameters.

function Get-DsFtpSettings {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [hashtable]$Overrides = @{}
    )
    $settings = [ordered]@{
        host = '192.168.1.151'; port = 5000; remoteDirectory = '/roms/nds'
        remoteName = 'game.nds'; user = 'anonymous'; password = ''
    }
    $sources = @(
        @{ path = (Join-Path $PSScriptRoot '..\config\ftp.json'); map = $null },
        @{ path = (Join-Path $ProjectPath '.ds-game-dev\project.json'); map = @{ romUploadName = 'remoteName' } },
        @{ path = (Join-Path $ProjectPath '.ds-game-dev\ftp.local.json'); map = $null }
    )
    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source.path)) { continue }
        $json = Get-Content -Raw -LiteralPath $source.path | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) {
            $key = $prop.Name
            if ($source.map) {
                if (-not $source.map.ContainsKey($key)) { continue }
                $key = $source.map[$key]
            }
            if ($settings.Contains($key) -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { $settings[$key] = $prop.Value }
        }
    }
    foreach ($key in $Overrides.Keys) { $settings[$key] = $Overrides[$key] }
    $settings.port = [int]$settings.port
    return $settings
}

function Assert-DsFtpReachable {
    param([Parameter(Mandatory)] $Settings, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($Settings.host, $Settings.port, $null, $null)
        $ok = $pending.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected
    } catch { $ok = $false } finally { $client.Close() }
    if (-not $ok) {
        throw "FTP_UNREACHABLE host=$($Settings.host) port=$($Settings.port). La DS no escucha en ese puerto: pide al usuario que abra ftpd.nds en la consola (y que esté en la misma red). No reintentes sin su aviso."
    }
}

function Get-DsFtpBase {
    param([Parameter(Mandatory)] $Settings)
    return "ftp://$($Settings.host):$($Settings.port)"
}
