[CmdletBinding()]
param([string]$ProjectPath)
# One DS_CHECK line per check, then DS_TOOLCHAIN=PASS|INCOMPLETE (exit 0/1).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
$missing = New-Object System.Collections.Generic.List[string]
function Report([string]$Name, [string]$Status, [string]$Detail = '') {
    Write-Output ("DS_CHECK {0}={1}{2}" -f $Name, $Status, $(if ($Detail) { " $Detail" } else { '' }))
    if ($Status -eq 'MISSING') { $script:missing.Add($Name) }
}

# Image and pinned id.
$image = 'skylyrac/blocksds:slim-latest'
if ($ProjectPath) {
    $cfgPath = Join-Path $ProjectPath '.ds-game-dev\project.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json
        if ($cfg.blocksdsImage) { $image = $cfg.blocksdsImage }
    }
}
$pinnedPath = Join-Path $root 'config\blocksds-image.json'
$pinned = if (Test-Path -LiteralPath $pinnedPath) { Get-Content -Raw -LiteralPath $pinnedPath | ConvertFrom-Json } else { $null }

$ErrorActionPreference = 'Continue'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Report 'docker' 'MISSING' 'Docker CLI no instalado'
} else {
    docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -ne 0) {
        Report 'docker' 'MISSING' 'daemon no responde: inicia Docker Desktop'
    } else {
        Report 'docker' 'OK'
        $id = docker image inspect $image --format '{{.Id}}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Report 'image' 'MISSING' "$image no cargada: ejecuta scripts/setup.ps1 o scripts/load-blocksds-image.ps1"
        } else {
            $id = "$id".Trim()
            if ($pinned -and $pinned.image -eq $image -and $pinned.id -and $pinned.id -ne $id) {
                Report 'image' 'WARN' "id=$id pinned=$($pinned.id) (la build puede diferir de la validada)"
            } else { Report 'image' 'OK' "id=$($id.Substring(0, [Math]::Min(19, $id.Length)))" }
        }
    }
}

# WSL, python3, libdesmume, gcc.
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Report 'wsl' 'MISSING' 'WSL2 no instalado (necesario para DeSmuME y GDB)'
} else {
    Start-DsWslKeepAlive
    $lib = Join-Path $root 'runtime\bin\libdesmume.so'
    $agent = Join-Path $root 'runtime\bin\desmume-agent'
    if ((-not (Test-Path -LiteralPath $lib)) -or (-not (Test-Path -LiteralPath $agent))) {
        Report 'runtime' 'MISSING' 'ejecuta scripts/setup.ps1'
    } else {
        Report 'runtime' 'OK'
        $libWsl = ConvertTo-DsWslPath $lib
        $py = "import ctypes,sys;l=ctypes.CDLL(sys.argv[1]);print('LOAD_OK');v=getattr(l,'desmume_agent_version',None);print('EXPORTED' if v else 'NOEXPORT')"
        $out = (& wsl.exe python3 -c $py $libWsl 2>$null | ForEach-Object { "$_" }) -join ' '
        if ($LASTEXITCODE -eq 127 -or -not $out) {
            Report 'wsl_python3' 'MISSING' 'python3 no disponible en WSL'
        } else {
            Report 'wsl_python3' 'OK'
            if ($out -match 'LOAD_OK') {
                $ver = ''
                if ($out -match 'EXPORTED') {
                    $py2 = "import ctypes,sys;l=ctypes.CDLL(sys.argv[1]);f=l.desmume_agent_version;f.restype=ctypes.c_char_p;print(f().decode())"
                    $ver = " agent_version=" + ((& wsl.exe python3 -c $py2 $libWsl 2>$null | ForEach-Object { "$_" }) -join ' ')
                }
                Report 'libdesmume' 'OK' ($ver.Trim())
            } else { Report 'libdesmume' 'MISSING' 'libdesmume.so no carga con ctypes en WSL' }
        }
    }
    $gcc = (& wsl.exe which gcc 2>$null | ForEach-Object { "$_" }) -join ''
    if ($gcc) { Report 'wsl_gcc' 'OK' } else { Report 'wsl_gcc' 'WARN' 'sin gcc en WSL: no hay tests host en C' }
}
$ErrorActionPreference = 'Stop'

# Informative only: project Python host tests may use the Windows interpreter.
$winPy = Get-Command python -ErrorAction SilentlyContinue
Report 'windows_python' $(if ($winPy) { 'OK' } else { 'WARN' }) $(if ($winPy) { '' } else { 'no encontrado (solo afecta a hostTests en Python)' })

if ($missing.Count) {
    Write-Output ('DS_TOOLCHAIN=INCOMPLETE missing=' + ($missing -join ','))
    exit 1
}
Write-Output 'DS_TOOLCHAIN=PASS'
