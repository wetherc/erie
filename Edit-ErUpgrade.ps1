<#
.SYNOPSIS
  Raises weapon reinforcement levels and spirit ash levels to their maximum.
.DESCRIPTION
  Two different edits, both 4 bytes wide:

  * WEAPONS: the reinforcement level is the last two digits of the weapon param id,
    which lives in the slot's GaItem table, not in the inventory record. The edit
    rewrites that u32 to (base + level), where the base carries the affinity so an
    infused weapon keeps its infusion.

    "Maximum" is per weapon and per build, read from data/<profile>/weaponlevels.tsv.
    Weapons whose ceiling is 0 are skipped (ammunition, "Unarmed", and vanilla's
    Meteorite Staff among them), because a level on those produces a param id with no
    matching row. Convergence puts most weapons at +15 rather than the +25 / +10 of the
    base game, and its own item description text ("Strengthens armaments to +10") is
    wrong; the regulation is the authority.

  * SPIRIT ASHES: these are goods, so the level is encoded in the id carried by the
    inventory handle. The edit rewrites the handle to 0xB0000000 | <max-level id>. The
    target id is looked up by NAME from the goods table ("Lone Wolf Ashes +10"), never
    by id arithmetic, because flasks and pots also use "+N" names but step ids by 2.

  Neither edit changes a record count, allocates an inventory_index, or moves anything,
  which puts both in the same risk class as a quantity edit. What is NOT verified is
  whether the slot's acquisition / unlock tables need to know about the new id. See
  SAVE-FORMAT.md section 11.3. Treat -Apply as experimental and keep the backup.

  DRY RUN BY DEFAULT. Nothing is written without -Apply.
.EXAMPLE
  .\Edit-ErUpgrade.ps1 -Save ER0000.cnv -Character Frieren
.EXAMPLE
  .\Edit-ErUpgrade.ps1 -Save ER0000.cnv -Character Frieren -Apply
#>
[CmdletBinding()]
param(
    # --- which save. Same block as every other entry point. ---
    [string]$Path,
    [string]$SaveFolder,
    [string]$Save,
    [ValidateSet('vanilla', 'convergence')][string]$Profile,
    [string]$ModDir,
    [switch]$BaseGame,
    # --- what to edit ---
    [string]$Character,
    [int[]]$Slot,
    # Optional ceiling on top of the per-weapon one. "No higher than", never "set to":
    # a weapon whose build ceiling is below this stops at its own ceiling. -1 = unset.
    [ValidateRange(-1, 25)][int]$MaxWeaponLevel = -1,
    [switch]$SkipWeapons,
    [switch]$SkipSpiritAshes,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

if ($Apply) { Assert-ErGameNotRunning }

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame

$bytes   = [IO.File]::ReadAllBytes($session.SavePath)
$prof    = $session.Profile
$goods   = Get-ErNameTable -Family Goods -Profile $prof
$vanilla = if ($BaseGame) { Get-ErProfile -Profile vanilla } else { $null }

$targets = @(Resolve-ErCharacters -Bytes $bytes -Character $Character -Slot $Slot)

$plan    = New-Object Collections.ArrayList
$refused = 0

foreach ($char in $targets) {
    $entry = $char.Entry
    Write-Host ("SLOT     {0} '{1}'  checksum {2}" -f $char.Index, $char.Name,
        $(if (Test-ErChecksum -Bytes $bytes -Entry $entry) { 'OK' } else { 'BAD' }))

    $arrays = @(Find-ErInventories -Bytes $bytes -Entry $entry)
    if (-not $arrays.Count) {
        if ($targets.Count -gt 1) {
            Write-Host ("  SKIP  no item array found in slot {0} - nothing planned for this character" -f $char.Index)
            continue
        }
        throw "No item array found in slot $($char.Index)"
    }

    # The -BaseGame startup gate. Per-item refusal below still guards each individual
    # write; this is here so a run that could achieve almost nothing says so before
    # doing the work.
    if ($vanilla -and -not (Test-ErBaseGameSafe -Bytes $bytes -Char $char -Vanilla $vanilla -Inventories $arrays)) {
        throw "Refusing to run under -BaseGame on '$($char.Name)' - see the list above."
    }

    if (-not $SkipWeapons) {
        $gaIndex = Get-ErGaItemIndex -Bytes $bytes -Entry $entry -Inventories $arrays
        $equip = @(Get-ErEquipment -Bytes $bytes -Entry $entry -Inventories $arrays `
                       -GaIndex $gaIndex -Profile $prof)
        foreach ($w in ($equip | Where-Object { $_.Kind -eq 'Weapon' })) {
            if (-not $w.Upgradeable) { continue }
            # Under -BaseGame the weapon itself has to be a base-game weapon, or the
            # record cannot survive the mod being removed regardless of what level it
            # carries. Reported separately from the ceiling clamp so a refusal is
            # visible.
            if ($vanilla -and -not (Test-ErItemExists -Profile $vanilla -Family Weapon -Id $w.BaseId)) {
                Write-Host ("  SKIP  {0} (id {1}) is not a base-game weapon - refused under -BaseGame" -f $w.Name, $w.BaseId)
                $refused++
                continue
            }
            $target = Get-ErWeaponCeiling -Profile $prof -BaseId $w.BaseId `
                                          -Requested $MaxWeaponLevel -BaseGameProfile $vanilla
            if ($target -le 0) { continue }
            if ($w.Level -ge $target) { continue }
            [void]$plan.Add([pscustomobject]@{
                Who    = $char.Name
                Entry  = $entry
                What   = 'Weapon'
                Offset = $w.GaOffset + 4
                Old    = [uint32]$w.ParamId
                New    = [uint32]($w.BaseId + $target)
                # Say so when the target is below what this build would allow, otherwise
                # a -BaseGame or -MaxWeaponLevel run looks like it is undershooting at
                # random.
                Label  = ('{0}  +{1} -> +{2}{3}' -f $w.Name, $w.Level, $target,
                          $(if ($target -lt $w.MaxLevel) { "   (clamped; $($prof.Name) allows +$($w.MaxLevel))" } else { '' }))
            })
        }
    }

    if (-not $SkipSpiritAshes) {
        foreach ($a in @(Get-ErSpiritAshes -Bytes $bytes -Entry $entry -Inventories $arrays -GoodsNames $goods)) {
            if ($null -eq $a.MaxId) { continue }
            if ($a.Level -ge $a.MaxLevel) { continue }
            if ($vanilla -and -not (Test-ErItemExists -Profile $vanilla -Family Goods -Id $a.MaxId)) {
                Write-Host ("  SKIP  {0} +{1} is not a base-game id - refused under -BaseGame" -f $a.Family, $a.MaxLevel)
                $refused++
                continue
            }
            [void]$plan.Add([pscustomobject]@{
                Who    = $char.Name
                Entry  = $entry
                What   = 'SpiritAsh'
                Offset = $a.Offset
                Old    = [uint32](2952790016 + $a.ItemId)   # 0xB0000000 | id
                New    = [uint32](2952790016 + $a.MaxId)
                Label  = ('{0}  +{1} -> +{2}' -f $a.Family, $a.Level, $a.MaxLevel)
            })
        }
    }
}

if ($refused) { Write-Host ("`n{0} item(s) refused under -BaseGame. Drop the flag to include them." -f $refused) }
if (-not $plan.Count) { Write-Host "`nNothing to change - everything is already at maximum, or there is nothing upgradeable here."; return }

Write-Host ("`nPLANNED CHANGES ({0})" -f $plan.Count)
foreach ($p in $plan) {
    Write-Host ("   {0,-16} {1,-10} 0x{2:x}  {3} -> {4}   {5}" -f $p.Who, $p.What, $p.Offset, $p.Old, $p.New, $p.Label)
}

if (-not $Apply) {
    Write-Host "`n(dry run - nothing written; re-run with -Apply to write)"
    return
}

# Sanity: every planned write must still find the value it expects.
foreach ($p in $plan) {
    $cur = [BitConverter]::ToUInt32($bytes, $p.Offset)
    if ($cur -ne $p.Old) { throw ("Offset 0x{0:x} holds {1}, expected {2} - refusing to write" -f $p.Offset, $cur, $p.Old) }
}

$backup = "$($session.SavePath).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
[IO.File]::Copy($session.SavePath, $backup)
Write-Host "`nBackup -> $backup"

$touched = @{}
foreach ($p in $plan) {
    [Array]::Copy([BitConverter]::GetBytes($p.New), 0, $bytes, $p.Offset, 4)
    $touched[$p.Entry.Index] = $p.Entry
}
foreach ($e in $touched.Values) { Update-ErChecksum -Bytes $bytes -Entry $e }
[IO.File]::WriteAllBytes($session.SavePath, $bytes)

$verify = [IO.File]::ReadAllBytes($session.SavePath)
$bad = @(Get-ErEntries -Bytes $verify | Where-Object { -not (Test-ErChecksum -Bytes $verify -Entry $_) })
if ($bad.Count) { throw "Checksum verification FAILED for: $(($bad | ForEach-Object { $_.Name }) -join ', ')" }
Write-Host ("Wrote {0} change(s). All {1} entry checksums verify." -f $plan.Count, @(Get-ErEntries -Bytes $verify).Count)
