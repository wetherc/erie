<#
.SYNOPSIS
  Lists a character's weapons, armour and spirit ashes with their upgrade levels.
.DESCRIPTION
  Show-ErInventory.ps1 can only name GOODS, because a goods id lives in the inventory
  handle itself. Weapons and armour carry a dynamic handle instead, and their real param
  id lives in the slot's GaItem table, so they show up there as "<cat 0x8 id 524>".
  This script resolves them.

  Weapon reinforcement level is the last two digits of the weapon param id
  (the affinity sits in the hundreds digits and is part of the base).
  Spirit ashes are goods whose level is encoded in the goods id, one name per level.

  Names and upgrade ceilings both come from the resolved PROFILE, so the same weapon
  reads "+10 of 25" under the base game and "+10 of 15" under Convergence.
.EXAMPLE
  .\Show-ErEquipment.ps1 -Save ER0000.cnv -Character Frieren
#>
[CmdletBinding()]
param(
    # --- which save. Same block as every other entry point. ---
    [string]$Path,
    [string]$SaveFolder,
    [string]$Save,
    [ValidateSet('vanilla', 'convergence')][string]$Profile,
    [string]$ModDir,
    # Read-only script, so this only annotates: items absent from the base game are
    # marked [mod].
    [switch]$BaseGame,
    # --- what to show ---
    [string]$Character,
    [int[]]$Slot,
    [switch]$IncludeArmour
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame

$bytes   = [IO.File]::ReadAllBytes($session.SavePath)
$prof    = $session.Profile
$goods   = Get-ErNameTable -Family Goods     -Profile $prof
$wname   = Get-ErNameTable -Family Weapon    -Profile $prof
$pname   = Get-ErNameTable -Family Protector -Profile $prof
$ladders = Get-ErAshLadders -GoodsNames $goods
$vanilla = if ($BaseGame) { Get-ErProfile -Profile vanilla } else { $null }

if ($Character) { $Slot = @(Resolve-ErSlot -Bytes $bytes -Character $Character) }

foreach ($c in @(Get-ErCharacters -Bytes $bytes)) {
    if (-not $c.IsOccupied) { continue }
    if ($null -ne $Slot -and $Slot.Count -and $c.Index -notin $Slot) { continue }

    $arrays = @(Find-ErInventories -Bytes $bytes -Entry $c.Entry)
    Write-Host ("`n=== slot {0} '{1}' | {2} array(s)" -f $c.Index, $c.Name, $arrays.Count)
    if (-not $arrays.Count) { Write-Host '   no item array found'; continue }

    $gaIndex = Get-ErGaItemIndex -Bytes $bytes -Entry $c.Entry -Inventories $arrays
    $equip = @(Get-ErEquipment -Bytes $bytes -Entry $c.Entry -Inventories $arrays `
                   -GaIndex $gaIndex -WeaponNames $wname -ProtectorNames $pname -Profile $prof)

    $weapons = @($equip | Where-Object { $_.Kind -eq 'Weapon' } | Sort-Object Name)
    Write-Host ("`n   WEAPONS ({0})" -f $weapons.Count)
    if (-not $weapons.Count) { Write-Host '      (none)' }
    foreach ($w in $weapons) {
        # The ceiling is per weapon and per build: there is no single "+25" or "+10"
        # answer. See SAVE-FORMAT.md section 6.5.
        # '/?' means this build defines no such weapon at all, not "ceiling unknown".
        $of   = if ($null -ne $w.MaxLevel) { "/$($w.MaxLevel)" } else { '/?' }
        $flag = if ($w.Upgradeable) { '' } else { '   [not upgradeable]' }
        $mark = if ($vanilla -and $null -ne $w.BaseId -and -not (Test-ErItemExists -Profile $vanilla -Family Weapon -Id $w.BaseId)) { '  [mod]' } else { '' }
        Write-Host ("      ga 0x{0:x}  id={1,-10} +{2}{3,-6} {4}{5}{6}" -f `
            $w.GaOffset, $w.ParamId, $w.Level, $of, $(if ($w.Name) { $w.Name } else { '<unnamed>' }), $mark, $flag)
    }

    if ($IncludeArmour) {
        $armour = @($equip | Where-Object { $_.Kind -eq 'Armour' } | Sort-Object Name)
        Write-Host ("`n   ARMOUR ({0}) - no reinforcement in Elden Ring" -f $armour.Count)
        foreach ($a in $armour) {
            $mark = if ($vanilla -and $null -ne $a.BaseId -and -not (Test-ErItemExists -Profile $vanilla -Family Protector -Id $a.BaseId)) { '  [mod]' } else { '' }
            Write-Host ("      ga 0x{0:x}  id={1,-10} {2}{3}" -f $a.GaOffset, $a.BaseId, $(if ($a.Name) { $a.Name } else { '<unnamed>' }), $mark)
        }
    }

    $ashes = @(Get-ErSpiritAshes -Bytes $bytes -Entry $c.Entry -Inventories $arrays `
                   -GoodsNames $goods -Ladders $ladders | Sort-Object Family)
    Write-Host ("`n   SPIRIT ASHES ({0})" -f $ashes.Count)
    if (-not $ashes.Count) { Write-Host '      (none)' }
    foreach ($a in $ashes) {
        $mark = if ($a.Level -ge $a.MaxLevel) { 'MAX' } else { ('-> +{0} (id {1})' -f $a.MaxLevel, $a.MaxId) }
        Write-Host ("      0x{0:x}  id={1,-8} +{2,-3} {3,-40} {4}" -f $a.Offset, $a.ItemId, $a.Level, $a.Name, $mark)
    }

    $unresolved = @(
        foreach ($inv in $arrays) {
            foreach ($it in (Get-ErInventoryItems -Bytes $bytes -Inventory $inv)) {
                if (-not $it.IsGoods -and -not $gaIndex.ContainsKey($it.Handle)) { $it }
            }
        })
    if ($unresolved.Count) {
        Write-Host ("`n   {0} non-goods record(s) had no GaItem entry in the scanned region" -f $unresolved.Count)
        Write-Host ('      categories: ' + (($unresolved | Group-Object Category | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '))
    }
}
Write-Host ''
