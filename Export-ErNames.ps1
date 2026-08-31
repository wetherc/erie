<#
.SYNOPSIS
  Builds data/<profile>/<family>names.tsv, the id -> display-name tables the save tools
  read, for either base-game Elden Ring or an installed mod.
.DESCRIPTION
  Two sources, one output shape:

    -Profile vanilla      reads the game's own encrypted archives (Data0-3.bhd/bdt, DLC.*)
    -Profile convergence  reads the mod's loose msg/engus/item*.msgbnd.dcx

  Mods such as The Convergence RENAME a subset of vanilla goods ids and leave the rest
  with stale vanilla names, so never assume an id's meaning; always regenerate after a
  mod update. The vanilla tables likewise need regenerating after a game patch.

  Pipeline for both: (archive ->) item*.msgbnd.dcx --Oodle--> BND4 --> *Name*.fmg --> TSV

  The archive holds SEVERAL Name FMGs per family: the base table plus one per DLC. All
  are read and merged (base -> dlc01 -> dlc02, later wins). Reading only GoodsName.fmg
  drops the entire DLC id range, which is where a mod's added items usually live.

  Requires oo2core_6_win64.dll from the game install (DCX payloads are Oodle Kraken).

  CONSTANTS. Reading the vanilla archives needs FromSoftware's public RSA keys and the
  BHD5 path-hash rule. They are baked in below as literals rather than fetched at run
  time. They have been stable across every Elden Ring patch so far, but if a future patch
  changes them this script is where a developer updates them. See the comment block on
  $ErBhdKeys.
.EXAMPLE
  .\Export-ErNames.ps1 -Profile vanilla
.EXAMPLE
  .\Export-ErNames.ps1 -Profile convergence
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('vanilla', 'convergence')][string]$Profile,
    [string]$GameDir  = 'D:\SteamLibrary\steamapps\common\ELDEN RING\Game',
    [string]$ModDir   = 'D:\ConvergenceER',
    # Skip discovery and read this msgbnd instead. Mod profiles only.
    [string]$Msgbnd,
    [string]$OodleDll,
    [ValidateSet('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem')]
    [string[]]$Family = @('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem'),
    [string]$DataDir = "$PSScriptRoot\data"
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ErArchiveLib.ps1"

if (-not $OodleDll) { $OodleDll = Join-Path $GameDir 'oo2core_6_win64.dll' }
Initialize-ErOodle -OodleDll $OodleDll

# --- gather the msgbnd payloads ----------------------------------------------
# Each element is a decompressed BND4 holding one archive's worth of FMGs.
$archives = New-Object Collections.Generic.List[byte[]]

if ($Profile -eq 'vanilla') {
    # The DLC msg archives live in DLC.bdt; the base ones in Data0.bdt. Both are scanned
    # so a game that has no DLC installed still produces a usable base table.
    $wanted = @('/msg/engus/item.msgbnd.dcx',
                '/msg/engus/item_dlc01.msgbnd.dcx',
                '/msg/engus/item_dlc02.msgbnd.dcx')
    $found = Get-ErArchiveFiles -GameDir $GameDir -Paths $wanted
    foreach ($w in $wanted) {
        if (-not $found.ContainsKey($w)) { Write-Warning "not present in this install: $w"; continue }
        Write-Host ("  {0,-34} {1,9:N0} bytes" -f (Split-Path $w -Leaf), $found[$w].Length)
        $archives.Add((Expand-ErDcx -Bytes $found[$w]))
    }
    if (-not $archives.Count) { throw "No item msgbnd found under $GameDir. Is -GameDir right?" }
}
else {
    if ($Msgbnd) { $paths = @($Msgbnd) }
    else {
        $dir = Join-Path $ModDir 'mod\msg\engus'
        if (-not (Test-Path $dir)) { throw "Mod message folder not found: $dir. Pass -ModDir or -Msgbnd." }
        $paths = @(Get-ChildItem -Path $dir -Filter 'item*.msgbnd.dcx' | Sort-Object Name | ForEach-Object { $_.FullName })
        if (-not $paths.Count) { throw "No item*.msgbnd.dcx under $dir" }
    }
    foreach ($p in $paths) {
        Write-Host ("  {0,-34} {1,9:N0} bytes" -f (Split-Path $p -Leaf), (Get-Item $p).Length)
        $archives.Add((Expand-ErDcx -Bytes ([IO.File]::ReadAllBytes($p))))
    }
}

# --- index every FMG by leaf name --------------------------------------------
# Later archives win on a collision, so the base -> dlc01 -> dlc02 read order matters.
$byLeaf = @{}
foreach ($bnd in $archives) {
    foreach ($kv in (Get-ErBnd4Files -Bytes $bnd).GetEnumerator()) { $byLeaf[$kv.Key] = $kv.Value }
}

# --- emit one TSV per family --------------------------------------------------
$outDir = Join-Path $DataDir $Profile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

foreach ($fam in $Family) {
    $names = @{}
    $seen = 0
    foreach ($suffix in @('', '_dlc01', '_dlc02')) {
        $leaf = "${fam}Name${suffix}.fmg"
        if (-not $byLeaf.ContainsKey($leaf)) { continue }
        $seen++
        $t = Read-ErFmgNames -Fmg $byLeaf[$leaf] -Label $leaf
        foreach ($k in $t.Keys) { $names[$k] = $t[$k] }
        Write-Host ("  {0,-26} {1,6} names" -f $leaf, $t.Count)
    }
    if ($seen -eq 0) { Write-Warning "no FMG found for family '$fam'"; continue }

    $target = Join-Path $outDir "$($fam.ToLower())names.tsv"
    $lines = New-Object Collections.Generic.List[string]
    foreach ($id in ($names.Keys | Sort-Object)) { $lines.Add("$id`t$($names[$id])") }
    [IO.File]::WriteAllLines($target, $lines, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $($lines.Count) names -> $target`n"
}
