# Contrato por conceptos + catalogo de ROM parcial (lo usan build-project.ps1 y build-partial-rom.ps1).
# Contrato: <proyecto>\.ds-game-dev\partial\<nombre>.txt, palabras = conceptos del catalogo.json de su carpeta.

function Read-PartialCatalog([string]$ContractPath) {
    $path = Join-Path (Split-Path -Parent $ContractPath) 'catalogo.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Falta el catalogo de conceptos: $path" }
    $raw = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $concepts = [ordered]@{}
    foreach ($c in $raw.conceptos.PSObject.Properties) {
        $conceptOptional = [bool]($c.Value.PSObject.Properties['opcional'] -and $c.Value.opcional)
        $entries = @(foreach ($a in @($c.Value.archivos)) {
            if ($a -is [string]) { [pscustomobject]@{ Pattern = $a; Con = @(); Optional = $conceptOptional } }
            else {
                [pscustomobject]@{
                    Pattern = $a.patron
                    Con = @(if ($a.PSObject.Properties['con']) { @($a.con) })
                    Optional = ($conceptOptional -or [bool]($a.PSObject.Properties['opcional'] -and $a.opcional))
                }
            }
        })
        $concepts[$c.Name.ToLowerInvariant()] = $entries
    }
    [pscustomobject]@{ Path = $path; Concepts = $concepts }
}

# Pattern against a path relative to nitrofiles/: 'dir/' = the whole folder, '*' = wildcard, otherwise a file.
function Test-PartialPattern([string]$Pattern, [string]$Rel) {
    $p = $Pattern.Replace('\', '/').TrimStart('/')
    if ($p.EndsWith('/')) { return $Rel.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) }
    return $Rel -like $p
}

# Entries (concept, pattern, optional) of the catalog that match a relative path, ignoring conditions.
function Find-PartialConcepts($Catalog, [string]$Rel) {
    foreach ($name in $Catalog.Concepts.Keys) {
        foreach ($e in $Catalog.Concepts[$name]) {
            if (Test-PartialPattern $e.Pattern $Rel) { [pscustomobject]@{ Concept = $name; Entry = $e } }
        }
    }
}

# Reads the contract, checks the concepts, expands them to files and enforces coverage of nitrofiles/.
function Resolve-PartialContract([string]$ContractPath, [string]$NitroRoot) {
    if (-not (Test-Path -LiteralPath $ContractPath)) { throw "Falta el contrato: $ContractPath" }
    $name = [IO.Path]::GetFileNameWithoutExtension($ContractPath)
    $catalog = Read-PartialCatalog $ContractPath
    $words = New-Object System.Collections.Generic.List[string]
    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($raw in Get-Content -LiteralPath $ContractPath) {
        $line = ($raw -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^archivo:\s*(.+)$') { $extra.Add($Matches[1].Trim().Replace('\', '/').Trim('/')); continue }
        foreach ($w in ($line -split '\s+')) { $words.Add($w.ToLowerInvariant()) }
    }
    $unknown = @($words | Where-Object { -not $catalog.Concepts.Contains($_) })
    if ($unknown.Count -gt 0) {
        throw ("Contrato ${name}: concepto desconocido: " + ($unknown -join ', ') + ". Validos: " + (@($catalog.Concepts.Keys) -join ', '))
    }
    $concepts = @($words | Select-Object -Unique)
    # Every file of nitrofiles/ must belong to some concept, so a new asset cannot be left out unnoticed.
    $all = @(Get-ChildItem -LiteralPath $NitroRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($NitroRoot.Length).TrimStart('\').Replace('\', '/') })
    $orphans = @($all | Where-Object { @(Find-PartialConcepts $catalog $_).Count -eq 0 })
    if ($orphans.Count -gt 0) {
        throw ("Catalogo incompleto: archivos de nitrofiles/ sin concepto (anadelos a $($catalog.Path)): " + (($orphans | Select-Object -First 20) -join ', ') + $(if ($orphans.Count -gt 20) { " ... (+$($orphans.Count - 20))" }))
    }
    $files = New-Object System.Collections.Generic.HashSet[string]
    foreach ($c in $concepts) {
        foreach ($e in $catalog.Concepts[$c]) {
            if (@($e.Con | Where-Object { $_ -and ($concepts -notcontains $_.ToLowerInvariant()) }).Count -gt 0) { continue }
            foreach ($f in $all) { if (Test-PartialPattern $e.Pattern $f) { [void]$files.Add($f) } }
        }
    }
    foreach ($x in $extra) {
        $hit = @($all | Where-Object { Test-PartialPattern $x $_ })
        if ($hit.Count -eq 0) { throw "Contrato ${name}: 'archivo: $x' no existe en nitrofiles/" }
        foreach ($f in $hit) { [void]$files.Add($f) }
    }
    $sorted = [string[]]@($files)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    [pscustomobject]@{ Name = $name; Concepts = $concepts; Files = $sorted; Catalog = $catalog; Extra = @($extra) }
}
