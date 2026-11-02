param([ValidateSet('Wsl','Docker')][string]$Backend = 'Wsl')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'runtime\source'
$runtime = Join-Path $root 'runtime\bin'
if (-not (Test-Path -LiteralPath $source)) { throw 'Falta la fuente fijada de DeSmuME incluida en la skill.' }
$sourceWsl = "/mnt/$($source.Substring(0,1).ToLowerInvariant())$($source.Substring(2).Replace('\','/'))"
$runtimeWsl = "/mnt/$($runtime.Substring(0,1).ToLowerInvariant())$($runtime.Substring(2).Replace('\','/'))"
& wsl bash -lc "set -e; cd '$sourceWsl'; meson setup --reconfigure build-agent -Dfrontend-gtk=false -Dfrontend-cli=false -Dwifi=false -Dgdb-stub=true; ninja -C build-agent; mkdir -p '$runtimeWsl'; cp -f build-agent/libdesmume.so '$runtimeWsl/libdesmume.so'"
if ($LASTEXITCODE -ne 0) { throw 'La reconstrucción de DeSmuME falló.' }
Write-Output 'DS_DESMUME_AGENT_BUILD=PASS'
