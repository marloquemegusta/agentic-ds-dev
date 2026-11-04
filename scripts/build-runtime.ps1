<#
Reconstruye runtime/bin/libdesmume.so desde un checkout limpio de upstream DeSmuME.

Flujo (todo en el sistema de archivos nativo de WSL, mucho mas rapido que /mnt/c):
  1. clona https://github.com/TASEmulators/desmume en ~/.cache/ds-agent-desmume/src (si falta)
     y lo deja en el commit fijado por runtime/SOURCE-VERSION (git reset --hard + clean);
  2. aplica runtime/patches/*.patch en orden y copia gdb_agent.cpp / gdb_thread.cpp;
  3. meson + ninja (frontend interface, sin GTK/CLI/wifi, con gdb-stub);
  4. copia libdesmume.so a runtime/bin y actualiza su linea en runtime/SHA256SUMS.

No usa runtime/source (checkout antiguo, obsoleto). Requiere WSL con git, meson, ninja,
gcc/g++, pkg-config y los dev de sdl2, glib, zlib, libpcap.
#>
param([ValidateSet('Wsl')][string]$Backend = 'Wsl')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root 'runtime'
$patches = Join-Path $runtime 'patches'
$bin = Join-Path $runtime 'bin'

$sv = Get-Content -LiteralPath (Join-Path $runtime 'SOURCE-VERSION') -Raw
if ($sv -notmatch 'upstream=([0-9a-f]{40})') { throw 'runtime/SOURCE-VERSION no contiene upstream=<commit de 40 hex>.' }
$commit = $Matches[1]

function ConvertTo-WslPath([string]$p) {
  $full = (Resolve-Path -LiteralPath $p).Path
  "/mnt/$($full.Substring(0,1).ToLowerInvariant())$($full.Substring(2).Replace('\','/'))"
}
$patchesWsl = ConvertTo-WslPath $patches
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$binWsl = ConvertTo-WslPath $bin

$script = @"
set -euo pipefail
WORK="`$HOME/.cache/ds-agent-desmume"
SRC="`$WORK/src"
BLD="`$WORK/build"
mkdir -p "`$WORK"
if [ ! -d "`$SRC/.git" ]; then git clone -q https://github.com/TASEmulators/desmume "`$SRC"; fi
cd "`$SRC"
git cat-file -e $commit^{commit} 2>/dev/null || git fetch -q origin
git reset -q --hard $commit
git clean -qfdx
for p in desmume-agent desmume-keypad-contract desmume-agent-2; do
  git apply "$patchesWsl/`$p.patch"
  echo "patch aplicado: `$p"
done
cp "$patchesWsl/gdb_agent.cpp" "$patchesWsl/gdb_thread.cpp" desmume/src/frontend/interface/
rm -rf "`$BLD"
cd desmume/src/frontend/interface
meson setup "`$BLD" -Dfrontend-gtk=false -Dfrontend-cli=false -Dwifi=false -Dgdb-stub=true >/dev/null
ninja -C "`$BLD"
cp -f "`$BLD/libdesmume.so" "$binWsl/libdesmume.so"
"@
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'ds-build-runtime.sh'
[IO.File]::WriteAllText($tmp, ($script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
& wsl bash (ConvertTo-WslPath $tmp)
if ($LASTEXITCODE -ne 0) { throw 'La reconstruccion de DeSmuME fallo.' }

# runtime/SHA256SUMS en formato sha256sum; solo se reemplaza la linea de libdesmume.so
$sumsPath = Join-Path $runtime 'SHA256SUMS'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $bin 'libdesmume.so')).Hash.ToLowerInvariant()
$lines = @()
if (Test-Path -LiteralPath $sumsPath) { $lines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_ -and $_ -notmatch '\sbin/libdesmume\.so$' }) }
$lines += "$hash  bin/libdesmume.so"
[IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Output "libdesmume.so sha256=$hash"
Write-Output 'DS_DESMUME_AGENT_BUILD=PASS'
