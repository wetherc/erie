<#
.SYNOPSIS
  Lists the characters in an Elden Ring save and the items each one holds.
.DESCRIPTION
  Slots are identified by character name, not by index. A slot number says nothing about
  which character is in it, so selecting by index can edit an unintended save.

  Every item array in a slot is listed. A slot holds more than one (held inventory plus
  storage box), so reporting only the largest omits items.

  Item names come from the profile the save resolves to: base game or Convergence. The
  two builds put different names on the same ids, so check the profile line printed at
  startup. If it is wrong, every name below it is wrong too.
.EXAMPLE
  .\Show-ErInventory.ps1
.EXAMPLE
  .\Show-ErInventory.ps1 -Save ER0000.cnv -Character Frieren -NameLike '*Stone*' -GoodsOnly
.EXAMPLE
  .\Show-ErInventory.ps1 -Path ...\ER0000.cnv -BaseGame      # flag anything not in the base game
#>
[CmdletBinding()]
param(
    # --- which save. Same block as every other entry point, resolved by the same
    #     function, so identical arguments always select the same file. ---
    [string]$Path,
    [string]$SaveFolder,
    [string]$Save,
    [ValidateSet('vanilla', 'convergence')][string]$Profile,
    [string]$ModDir,
    # Read-only script, so this only annotates: rows whose id does not exist in the base
    # game are marked [mod].
    [switch]$BaseGame,
    # --- what to show ---
    [string]$Character,
    [int[]]$Slot,
    [string]$NameLike,
    [int[]]$ItemId,
    [switch]$GoodsOnly
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame

$bytes   = [IO.File]::ReadAllBytes($session.SavePath)
$names   = Get-ErNameTable -Family Goods -Profile $session.Profile
$vanilla = if ($BaseGame) { Get-ErProfile -Profile vanilla } else { $null }
Write-Host ("SIZE     {0:N0} bytes" -f $bytes.Length)

$chars = @(Get-ErCharacters -Bytes $bytes)
Write-Host "`nCHARACTERS"
foreach ($c in $chars) {
    if (-not $c.IsOccupied) { continue }
    Write-Host ("   slot {0}  {1}" -f $c.Index, $c.Name)
}
Write-Host ''

if ($Character) { $Slot = @(Resolve-ErSlot -Bytes $bytes -Character $Character) }

foreach ($c in $chars) {
    if (-not $c.IsOccupied) { continue }
    if ($null -ne $Slot -and $Slot.Count -and $c.Index -notin $Slot) { continue }

    $entry = $c.Entry
    $arrays = @(Find-ErInventories -Bytes $bytes -Entry $entry)
    $sum = if ($arrays.Count) { ($arrays | Measure-Object -Property Count -Sum).Sum } else { 0 }
    Write-Host ("=== slot {0} '{1}' | {2} array(s), {3} records | checksum {4}" -f `
        $c.Index, $c.Name, $arrays.Count, $sum,
        $(if (Test-ErChecksum -Bytes $bytes -Entry $entry) { 'OK' } else { 'BAD' }))
    if (-not $arrays.Count) { Write-Host "   no item array found`n"; continue }

    $n = 0
    foreach ($inv in $arrays) {
        $n++
        $items = @(Get-ErInventoryItems -Bytes $bytes -Inventory $inv)
        $maxIdx = if ($items.Count) { ($items | Measure-Object -Property InvIndex -Maximum).Maximum } else { 0 }
        Write-Host ("   [array {0}] 0x{1:x}-0x{2:x} | count field 0x{3:x} | {4} items | highest inventory_index {5}" -f `
            $n, $inv.ArrayStart, $inv.ArrayEnd, $inv.CountOffset, $inv.Count, $maxIdx)

        foreach ($it in $items) {
            if ($GoodsOnly -and -not $it.IsGoods) { continue }
            if ($ItemId -and $it.ItemId -notin $ItemId) { continue }
            $nm = if ($it.IsGoods -and $names.ContainsKey($it.ItemId)) { $names[$it.ItemId] } else { "<cat $($it.Category) id $($it.ItemId)>" }
            if ($NameLike -and $nm -notlike $NameLike) { continue }
            # Existence is asked of the PARAM tables, never of the names: a mod leaves
            # stale vanilla names on ids the base game never defined.
            $mark = if ($vanilla -and $it.IsGoods -and -not (Test-ErItemExists -Profile $vanilla -Family Goods -Id $it.ItemId)) { '  [mod]' } else { '' }
            Write-Host ("      0x{0:x}  id={1,-7} qty={2,-6} idx={3,-6} {4}{5}" -f $it.Offset, $it.ItemId, $it.Quantity, $it.InvIndex, $nm, $mark)
        }
    }
    Write-Host ''
}
