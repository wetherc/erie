<#
.SYNOPSIS
  Builds data/<profile>/paramids.tsv and data/<profile>/weaponlevels.tsv from a
  regulation.bin: the tables that let the editor tell "this item exists in this build"
  from "this item is modded", and cap upgrades at what the build actually supports.
.DESCRIPTION
  Names (Export-ErNames.ps1) say what an id is CALLED. Params say whether it EXISTS and
  how far it upgrades, which is what validation needs. They are not the same set: some
  param rows have no name, and mods leave stale names behind on ids they never defined.

  Two outputs per profile:

    paramids.tsv      family <TAB> id      one line per row of each equipment param
    weaponlevels.tsv  baseId <TAB> maxLvl  reinforcement ceiling per weapon

  Elden Ring stores no per-level weapon rows, so the ceiling is derived through
  reinforceTypeId. See the comment block in ErArchiveLib.ps1. This is the only param
  FIELD the toolkit decodes; everything else is row ids, which need no paramdef.

  ZSTD-compressed regulations (current game patches) need Node.js v23+ on PATH. That is
  an export-time dependency only; the save editor never touches this code.
.EXAMPLE
  .\Export-ErParamData.ps1 -Profile vanilla
.EXAMPLE
  .\Export-ErParamData.ps1 -Profile convergence
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('vanilla', 'convergence')][string]$Profile,
    [string]$GameDir = 'D:\SteamLibrary\steamapps\common\ELDEN RING\Game',
    [string]$ModDir  = 'D:\ConvergenceER',
    # Skip discovery and read this regulation.bin instead.
    [string]$Regulation,
    [string]$OodleDll,
    [string]$DataDir = "$PSScriptRoot\data"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ErArchiveLib.ps1"

if (-not $OodleDll) { $OodleDll = Join-Path $GameDir 'oo2core_6_win64.dll' }
Initialize-ErOodle -OodleDll $OodleDll

if (-not $Regulation) {
    $Regulation = if ($Profile -eq 'vanilla') { Join-Path $GameDir 'regulation.bin' }
                  else { Join-Path $ModDir 'mod\regulation.bin' }
}
if (-not (Test-Path $Regulation)) { throw "regulation.bin not found: $Regulation" }
Write-Host "READ  $Regulation"

# Family name -> the param that defines it. These are the five families the save's
# inventory records can refer to.
$paramForFamily = [ordered]@{
    Goods     = 'EquipParamGoods'
    Weapon    = 'EquipParamWeapon'
    Protector = 'EquipParamProtector'
    Accessory = 'EquipParamAccessory'
    Gem       = 'EquipParamGem'
}

$files  = Get-ErRegulationFiles -Path $Regulation
$params = Get-ErRegulationParams -Path $Regulation -Files $files -Only @($paramForFamily.Values)

$outDir = Join-Path $DataDir $Profile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- paramids.tsv -------------------------------------------------------------
$lines = New-Object Collections.Generic.List[string]
foreach ($fam in $paramForFamily.Keys) {
    $p = $paramForFamily[$fam]
    if (-not $params.ContainsKey($p)) { Write-Warning "regulation has no $p"; continue }
    $ids = @($params[$p])
    foreach ($id in $ids) { $lines.Add("$fam`t$id") }
    Write-Host ("  {0,-10} {1,6} rows" -f $fam, $ids.Count)
}
$target = Join-Path $outDir 'paramids.tsv'
[IO.File]::WriteAllLines($target, $lines, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $($lines.Count) ids -> $target"

# --- weaponlevels.tsv ---------------------------------------------------------
$levels = Get-ErWeaponMaxLevels -Path $Regulation -Files $files
$lines = New-Object Collections.Generic.List[string]
foreach ($id in ($levels.Keys | Sort-Object)) { $lines.Add("$id`t$($levels[$id])") }
$target = Join-Path $outDir 'weaponlevels.tsv'
[IO.File]::WriteAllLines($target, $lines, [Text.UTF8Encoding]::new($false))

$dist = $levels.Values | Group-Object | Sort-Object { [int]$_.Name }
Write-Host ("  ceilings: " + (($dist | ForEach-Object { "+$($_.Name) x$($_.Count)" }) -join '  '))
Write-Host "Wrote $($lines.Count) weapon ceilings -> $target"
