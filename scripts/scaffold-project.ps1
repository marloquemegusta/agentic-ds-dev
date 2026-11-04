[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectPath,
    [string]$Title = 'NDS Game'
)
if (-not (Test-Path -LiteralPath $ProjectPath)) { New-Item -ItemType Directory -Force -Path $ProjectPath | Out-Null }
$root = (Resolve-Path -LiteralPath $ProjectPath).Path
$skillRoot = Split-Path -Parent $PSScriptRoot
foreach ($dir in @('source', 'include', 'tests', 'scenarios', 'tools', 'artifacts', '.ds-game-dev', 'docs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null
}

$configPath = Join-Path $root '.ds-game-dev\project.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $config = [ordered]@{
        title = $Title
        rom = 'game.nds'
        outputRom = 'game-blocksds.nds'
        buildTemplate = 'skill-default'
        blocksdsImage = 'skylyrac/blocksds:slim-latest'
        copy = @(
            [ordered]@{ source = 'source'; destination = 'arm9/source' },
            [ordered]@{ source = 'include'; destination = 'arm9/include' }
        )
        hostTests = @()
        scenarioDirectory = 'scenarios'
        romUploadName = 'game.nds'
    }
    # UTF-8 without BOM so any JSON reader accepts it.
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}

# Starter files (main.c, smoke scenario, .gitignore, example C test...) from the
# skill, never overwriting what the project already has.
$starter = Join-Path $skillRoot 'templates\project'
$copied = 0
if (Test-Path -LiteralPath $starter) {
    foreach ($file in Get-ChildItem -LiteralPath $starter -Recurse -File -Force) {
        $target = Join-Path $root $file.FullName.Substring($starter.Length).TrimStart('\')
        if (Test-Path -LiteralPath $target) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $copied++
    }
}
Write-Output "DS_SCAFFOLD=READY project=$root starter_files=$copied"
Write-Output 'NEXT=Ask product questions; draft project documents and wait for approval before writing them.'
