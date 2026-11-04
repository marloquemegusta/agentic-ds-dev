[CmdletBinding()]
param(
    [string]$ReleaseTag = 'latest',
    [string]$Repo = 'marloquemegusta/agentic-ds-dev',
    [switch]$Force,
    # Keep the extracted runtime even if it does not match runtime/SHA256SUMS.
    [switch]$AllowUnverified
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wsl-common.ps1')
$root = Split-Path -Parent $PSScriptRoot
$runtimeBin = Join-Path $root 'runtime\bin'
$libPath = Join-Path $runtimeBin 'libdesmume.so'
$agentPath = Join-Path $runtimeBin 'desmume-agent'

New-Item -ItemType Directory -Force -Path $runtimeBin | Out-Null

$needsRuntime = $Force -or (-not (Test-Path -LiteralPath $libPath)) -or (-not (Test-Path -LiteralPath $agentPath))

if ($needsRuntime) {
    Write-Host "[1/3] Preparando runtime DeSmuME headless..."
    
    # 1. Comprobar si existe un archivo local previo
    $localArchive = Join-Path $root 'desmume-runtime-linux-x64.tar.gz'
    $archivePath = Join-Path $env:TEMP "desmume-runtime-linux-x64.tar.gz"

    if (Test-Path -LiteralPath $localArchive) {
        Copy-Item -LiteralPath $localArchive -Destination $archivePath -Force
        Write-Host "  -> Usando archivo de runtime local."
    } else {
        $url = if ($ReleaseTag -eq 'latest') {
            "https://github.com/$Repo/releases/latest/download/desmume-runtime-linux-x64.tar.gz"
        } else {
            "https://github.com/$Repo/releases/download/$ReleaseTag/desmume-runtime-linux-x64.tar.gz"
        }
        Write-Host "  -> Descargando runtime precompilado desde $url ..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
        } catch {
            Write-Warning "No se pudo descargar de GitHub Releases ($($_.Exception.Message))."
        }
    }

    if (Test-Path -LiteralPath $archivePath) {
        $tarWsl = ConvertTo-DsWslPath $archivePath
        $destWsl = ConvertTo-DsWslPath $runtimeBin
        & wsl tar -xzf $tarWsl -C $destWsl
        & wsl chmod +x "$destWsl/desmume-agent" "$destWsl/libdesmume.so"
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    }

    if ((-not (Test-Path -LiteralPath $libPath)) -or (-not (Test-Path -LiteralPath $agentPath))) {
        Write-Warning "El runtime precompilado no esta listo. Puedes construirlo con scripts/build-runtime.ps1 si dispones de herramientas en WSL."
    } else {
        # Verify the extracted binaries against runtime/SHA256SUMS ("<sha256>  <path relative to runtime/>").
        $sums = Join-Path $root 'runtime\SHA256SUMS'
        if (Test-Path -LiteralPath $sums) {
            $bad = @()
            foreach ($line in Get-Content -LiteralPath $sums) {
                if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(\S+)$') { continue }
                $target = Join-Path (Join-Path $root 'runtime') $Matches[2]
                $actual = if (Test-Path -LiteralPath $target) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } else { '' }
                if ($actual -ne $Matches[1].ToUpperInvariant()) { $bad += $Matches[2] }
            }
            if ($bad.Count -gt 0) {
                if ($AllowUnverified) { Write-Warning "Checksum distinto en: $($bad -join ', '). Se mantiene por -AllowUnverified." }
                else { throw "Checksum distinto en: $($bad -join ', ') (ver runtime/SHA256SUMS). Usa -AllowUnverified solo si confias en el origen." }
            } else { Write-Host "  -> Runtime verificado con SHA256SUMS." }
        }
        Write-Host "  -> Runtime DeSmuME instalado correctamente."
    }
} else {
    Write-Host "[1/3] Runtime DeSmuME verificado en $runtimeBin."
}

# 2. Verificar o cargar contenedor Docker BlocksDS
Write-Host "[2/3] Comprobando imagen Docker de BlocksDS..."
$image = 'skylyrac/blocksds:slim-latest'
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) {
        $tar = Join-Path $root 'images\blocksds-slim-latest.tar'
        if (Test-Path -LiteralPath $tar) {
            Write-Host "  -> Cargando imagen offline desde $tar ..."
            docker load --input $tar
        } else {
            Write-Host "  -> Descargando imagen desde Docker Hub ($image)..."
            docker pull $image
        }
    } else {
        Write-Host "  -> Imagen Docker $image presente."
    }
} else {
    Write-Warning "Docker no esta instalado o no esta en el PATH. Necesario para compilar ROMs."
}

# 3. Validacion general del toolchain
Write-Host "[3/3] Validando estado general..."
& (Join-Path $PSScriptRoot 'check-toolchain.ps1')

Write-Output "DS_SETUP=PASS"
