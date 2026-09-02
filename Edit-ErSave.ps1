<#
.SYNOPSIS
  Interactive editor for an Elden Ring save: pick a character, pick an item, change it.
.DESCRIPTION
  The other scripts each do one thing to a selection given on the command line. This one
  is the front end: it shows what the character actually holds and edits it a piece at a
  time, which is the only practical way to work when a character holds 600+ records.

  It resolves the save, the build and the character through exactly the same helpers as
  every other entry point (Resolve-ErSession, Resolve-ErCharacters), so the same
  arguments select the same save here as anywhere else.

  WHAT IT CAN CHANGE
    weapons      reinforcement level, validated against the ceiling THIS build gives
                 THAT weapon (Get-ErWeaponCeiling; there is no single "+25")
    spirit ashes level, chosen from the ladder its name table actually defines
                 (grave- and ghost-glovewort spirits alike)
    goods        stack quantity, 1-999
    runes        the count carried in hand, 0-999,999,999, with the option to raise
                 rune memory (the lifetime total) alongside it

  Goods are offered as one list, key items and upgrade materials included. The operation
  on offer is "set the stack quantity", which is meaningful for anything that stacks, and
  every rule for splitting "consumable" from the rest is a guess at naming rather than a
  fact in the file. The prompt says so rather than quietly filtering.

  EVERY write is confirmed, then verified: the value is read back from disk and all entry
  checksums are re-checked. One timestamped backup is taken before the first write of the
  session. The game must not be running. That is re-checked before every write, not just
  at startup, because a REPL session is long enough for it to be launched halfway through.

  Interactive by definition: it refuses to start with stdin redirected rather than hang.

  Every list - the menu, the characters, the 600 items - is the same prompt: arrow keys
  move the highlight, typing searches, Enter takes what is highlighted, Esc goes back.
  Where a menu cannot be drawn it falls back to numbered pages by itself; see
  Select-ErItem in ErProfileLib.ps1.

  IN BULK. On the three item lists, Tab ticks rows (Ctrl+A ticks everything the search
  shows) and Enter takes all of them. One value is then asked for and applied to the lot:
  a quantity for goods, a level for weapons and ashes, with each weapon and each ash
  clamped to its own ceiling rather than the whole thing being refused because one of
  them cannot go that high. What cannot take the value at all is reported and left alone.

  A bulk edit is ONE plan, ONE confirmation and ONE write: the plan is printed, every
  offset is checked to still hold what the plan was built from, and if any one of them
  does not, nothing at all is written. A half-applied bulk edit is the outcome worth
  going out of the way to avoid.
.EXAMPLE
  .\Edit-ErSave.ps1
.EXAMPLE
  .\Edit-ErSave.ps1 -Save ER0000.cnv -Character Frieren
.EXAMPLE
  .\Edit-ErSave.ps1 -Save ER0000.sl2 -BaseGame
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
    # --- where to start. Both optional here: the REPL can ask. ---
    [string]$Character,
    [int[]]$Slot,
    [ValidateRange(1, 200)][int]$PageSize = 20
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

# The write path itself - the plan, the one confirmation, the backup, the read-back - is
# Invoke-ErSaveWriteBatch in ErProfileLib.ps1, along with $script:ErBackup. What is left
# here is which items to write and what to put in them.

# ==============================================================================
#  Reading a character's editable items
# ==============================================================================

function Get-ErArrayIndexOf {
    <#  Which held-item array an offset falls in.

        Worth showing in the UI: a slot has several arrays and the storage box mirrors
        the held inventory, so the same item name appears twice and editing the copy
        instead of the original is a confusing near-miss: it looks like the edit simply
        did not take.  #>
    param([Parameter(Mandatory)]$Arrays, [Parameter(Mandatory)][int]$Offset)
    for ($i = 0; $i -lt $Arrays.Count; $i++) {
        if ($Offset -ge $Arrays[$i].ArrayStart -and $Offset -lt $Arrays[$i].ArrayEnd) { return $i }
    }
    -1
}

function Read-ErSlotState {
    <#  Everything the REPL needs about one character, read once.

        Read once by design. A full pass over a large character measures about 13
        seconds on this machine, almost all of it the byte-aligned scans, so re-reading
        after every edit would make the tool unusable. Writes patch these objects in
        place instead: the new value is already known at that point, so nothing is
        being guessed.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Char,
        [Parameter(Mandatory)]$Prof
    )
    Write-Host ("`nReading slot {0} '{1}' - a few seconds..." -f $Char.Index, $Char.Name)

    $arrays = @(Find-ErInventories -Bytes $Bytes -Entry $Char.Entry)
    if (-not $arrays.Count) { throw "No item array found in slot $($Char.Index)." }
    $gaIndex = Get-ErGaItemIndex -Bytes $Bytes -Entry $Char.Entry -Inventories $arrays
    $goodsN  = Get-ErNameTable -Family Goods -Profile $Prof
    $ladders = Get-ErAshLadders -GoodsNames $goodsN

    $weapons = @(Get-ErEquipment -Bytes $Bytes -Entry $Char.Entry -Inventories $arrays `
                     -GaIndex $gaIndex -Profile $Prof |
                 Where-Object { $_.Kind -eq 'Weapon' })
    foreach ($w in $weapons) {
        Add-Member -InputObject $w -NotePropertyName Array -Force `
                   -NotePropertyValue (Get-ErArrayIndexOf -Arrays $arrays -Offset $w.RecordOffset)
        # Name stays as it is. $null there means "this build has no name for the id",
        # which the weapon action reports. Display is only what to put on screen, and a
        # blank row is worse than a visible "<weapon 3070000>".
        Add-Member -InputObject $w -NotePropertyName Display -Force `
                   -NotePropertyValue (Get-ErItemName -Profile $Prof -Family Weapon -Id $w.BaseId)
    }

    $ashes = @(Get-ErSpiritAshes -Bytes $Bytes -Entry $Char.Entry -Inventories $arrays `
                   -GoodsNames $goodsN -Ladders $ladders)
    $ashAt = @{}
    foreach ($a in $ashes) {
        Add-Member -InputObject $a -NotePropertyName Array -Force `
                   -NotePropertyValue (Get-ErArrayIndexOf -Arrays $arrays -Offset $a.Offset)
        $ashAt[$a.Offset] = $true
    }

    # Goods are collected here rather than through a library helper because the array an
    # item came from is part of what has to be shown, and the record iterator does not
    # carry it.
    $goods = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $arrays.Count; $i++) {
        foreach ($it in (Get-ErInventoryItems -Bytes $Bytes -Inventory $arrays[$i])) {
            if (-not $it.IsGoods) { continue }
            if ($ashAt.ContainsKey($it.Offset)) { continue }   # listed under spirit ashes
            [void]$goods.Add([pscustomobject]@{
                Offset   = $it.Offset
                ItemId   = $it.ItemId
                Name     = $(if ($goodsN.ContainsKey($it.ItemId)) { $goodsN[$it.ItemId] } else { $null })
                Display  = (Get-ErItemName -Profile $Prof -Family Goods -Id $it.ItemId)
                Quantity = $it.Quantity
                Array    = $i
            })
        }
    }

    # $null when the player block could not be located. The runes action reports that;
    # everything else in here is independent of it, so a miss must not stop the session.
    $player = Get-ErPlayerData -Bytes $Bytes -Char $Char

    [pscustomobject]@{
        Char    = $Char
        Arrays  = $arrays
        Ladders = $ladders
        GoodsN  = $goodsN
        Player  = $player
        Weapons = @($weapons | Sort-Object @{ E = { $_.Display } }, ParamId)
        Ashes   = @($ashes   | Sort-Object Family, Level)
        Goods   = @($goods   | Sort-Object @{ E = { $_.Display } }, ItemId)
    }
}

function Open-ErSlot {
    <#  Gate a character under -BaseGame, then read its state. Startup and the "change
        character" action both go through here so the two paths cannot diverge: a gate
        the change-character path skipped would be worse than no gate at all.

        Returns $null when -BaseGame refuses the character. In the loop that means "keep
        the slot you already had"; at startup it is fatal.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Char,
        [Parameter(Mandatory)]$Prof,
        $Vanilla
    )
    if ($Vanilla) {
        Write-Host ("`nChecking '{0}' against base-game rules..." -f $Char.Name)
        if (-not (Test-ErBaseGameSafe -Bytes $Bytes -Char $Char -Vanilla $Vanilla)) { return $null }
    }
    Read-ErSlotState -Bytes $Bytes -Char $Char -Prof $Prof
}

# ==============================================================================
#  Prompts
# ==============================================================================

function Select-ErFromList {
    <#  Pick one item out of a list that is too long to print.

        Everything about how the picking works lives in Select-ErItem (ErProfileLib):
        arrow keys and a search box on a real console, a numbered page-at-a-time prompt
        anywhere else. What stays here is the one case the picker cannot answer, an empty
        list, which needs a message and an acknowledgement rather than a silent $null.

        Returns the chosen item, or $null for Esc. With -Multi it returns an array of
        items instead, still $null for Esc.  #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Label,
        [int]$PageSize = 20,
        [switch]$Multi
    )
    if (-not $Items.Count) {
        Write-Host "`n  $Title - none held."
        [void](Read-ErLine -Prompt '  (Enter to go back)')
        return $null
    }
    Select-ErItem -Title $Title -Items $Items -Label $Label -PageSize $PageSize -Multi:$Multi
}

# ==============================================================================
#  Writing
# ==============================================================================

function Invoke-ErWeaponAction {
    <#  Set the reinforcement level on one weapon or on a whole tick-list of them.

        One level is asked for, and each weapon takes as much of it as ITS OWN ceiling
        allows. That is the only sensible reading of "+25 on these twelve" when a somber
        weapon stops at +10, and it makes "everything as high as it goes" the same
        operation as any other: ask for the highest level on offer.  #>
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $picked = Get-ErPicked (Select-ErFromList -Title 'WEAPONS' -Items $State.Weapons -PageSize $PageSize -Multi -Label {
        param($x)
        $cap = if ($null -ne $x.MaxLevel) { "/$($x.MaxLevel)" } else { '/?' }
        '{0,-38} +{1}{2,-5} a{3}  id {4}' -f `
            $x.Display, $x.Level, $cap, $x.Array, $x.ParamId
    })
    if (-not $picked.Count) { return }

    # Work out what each one can actually take before asking for anything, so the prompt
    # can offer a range that means something and the refusals are all reported together.
    $usable  = New-Object Collections.ArrayList
    $reasons = New-Object Collections.ArrayList
    foreach ($w in $picked) {
        if (-not $w.Upgradeable) {
            # MaxLevel null and MaxLevel 0 are different answers: "this build has no such
            # weapon" versus "this weapon has no reinforcement path". Say which.
            if ($null -eq $w.MaxLevel) {
                [void]$reasons.Add(('{0} (id {1}) is not defined by the {2} build at all - nothing written here could be trusted to load' -f $w.Display, $w.BaseId, $Prof.Name))
            } else {
                [void]$reasons.Add(('{0} does not reinforce in the {1} build (ceiling +0)' -f $w.Display, $Prof.Name))
            }
            continue
        }
        if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Weapon -Id $w.BaseId)) {
            [void]$reasons.Add(('{0} (id {1}) is not a base-game weapon - refused under -BaseGame' -f $w.Display, $w.BaseId))
            continue
        }
        $cap = Get-ErWeaponCeiling -Profile $Prof -BaseId $w.BaseId -BaseGameProfile $Vanilla
        if ($cap -le 0) {
            [void]$reasons.Add(('{0} has no reinforcement level available under the current rules' -f $w.Display))
            continue
        }
        [void]$usable.Add([pscustomobject]@{ W = $w; Cap = $cap })
    }
    Write-ErLeftAlone -Reasons @($reasons)
    if (-not $usable.Count) { return }

    $capMax = ($usable | ForEach-Object { $_.Cap } | Measure-Object -Maximum).Maximum
    if ($usable.Count -eq 1) {
        $w = $usable[0].W
        if ($Vanilla -and $capMax -lt $w.MaxLevel) {
            Write-Host ("  ceiling +{0} under -BaseGame ({1} would allow +{2})." -f $capMax, $Prof.Name, $w.MaxLevel)
        }
        $prompt = "  Level for '{0}' (now +{1})" -f $w.Display, $w.Level
    }
    else {
        Write-Host ("`n  {0} weapon(s) selected; each is clamped to its own ceiling, the highest here being +{1}." -f $usable.Count, $capMax)
        $prompt = '  Level for all {0}' -f $usable.Count
    }
    $lvl = Read-ErInt -Prompt $prompt -Min 0 -Max $capMax
    if ($null -eq $lvl) { return }

    $edits   = New-Object Collections.ArrayList
    $targets = New-Object Collections.ArrayList
    $skipped = New-Object Collections.ArrayList
    foreach ($u in $usable) {
        $w   = $u.W
        $tgt = [Math]::Min($lvl, $u.Cap)
        if ($tgt -eq $w.Level) {
            [void]$skipped.Add(('{0} is already +{1}' -f $w.Display, $w.Level))
            continue
        }
        $note = if ($tgt -lt $lvl) { ' (its ceiling)' } else { '' }
        [void]$targets.Add([pscustomobject]@{ W = $w; Level = $tgt })
        [void]$edits.Add((New-ErEdit -Offset ($w.GaOffset + 4) -Old ([uint32]$w.ParamId) `
            -New ([uint32]($w.BaseId + $tgt)) -Label ('{0}  +{1} -> +{2}{3}' -f $w.Display, $w.Level, $tgt, $note)))
    }
    Write-ErLeftAlone -Reasons @($skipped)
    if (-not $edits.Count) { return }

    if (Invoke-ErSaveWriteBatch -Session $Session -Bytes $Bytes -Entry $State.Char.Entry -Edits @($edits)) {
        foreach ($t in $targets) {
            $t.W.ParamId = [uint32]($t.W.BaseId + $t.Level)
            $t.W.Level   = $t.Level
        }
    }
}

function Invoke-ErAshAction {
    <#  Set the level on one spirit ash or on a whole tick-list of them. As with weapons,
        one level is asked for and each ash takes as much of it as its own ladder holds.  #>
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $picked = Get-ErPicked (Select-ErFromList -Title 'SPIRIT ASHES' -Items $State.Ashes -PageSize $PageSize -Multi -Label {
        param($x) '{0,-38} +{1}/{2,-4} a{3}  id {4}' -f $x.Family, $x.Level, $x.MaxLevel, $x.Array, $x.ItemId
    })
    if (-not $picked.Count) { return }

    $usable  = New-Object Collections.ArrayList
    $reasons = New-Object Collections.ArrayList
    foreach ($a in $picked) {
        if (-not $State.Ladders.ContainsKey($a.Family)) {
            [void]$reasons.Add(('{0} has no ladder in this build' -f $a.Family))
            continue
        }
        [void]$usable.Add($a)
    }
    Write-ErLeftAlone -Reasons @($reasons)
    if (-not $usable.Count) { return }

    $capMax = ($usable | ForEach-Object { $State.Ladders[$_.Family].Max } | Measure-Object -Maximum).Maximum
    if ($usable.Count -eq 1) {
        $a = $usable[0]
        # The ladder is read out of the name table, one entry per level, so a level this
        # build simply does not define is absent here too. Never step the id
        # arithmetically: flasks also carry "+N" names but step by 2.
        $levels = @($State.Ladders[$a.Family].ByLevel.Keys | Sort-Object)
        Write-Host ("  '{0}' has levels: {1}" -f $a.Family, ($levels -join ', '))
        $prompt = "  Level for '{0}' (now +{1})" -f $a.Family, $a.Level
    }
    else {
        Write-Host ("`n  {0} spirit ash(es) selected; each is clamped to the top of its own ladder, the highest here being +{1}." -f $usable.Count, $capMax)
        $prompt = '  Level for all {0}' -f $usable.Count
    }
    $lvl = Read-ErInt -Prompt $prompt -Min 0 -Max $capMax
    if ($null -eq $lvl) { return }

    $edits   = New-Object Collections.ArrayList
    $targets = New-Object Collections.ArrayList
    $skipped = New-Object Collections.ArrayList
    foreach ($a in $usable) {
        $ladder = $State.Ladders[$a.Family]
        $tgt    = [Math]::Min($lvl, $ladder.Max)
        if (-not $ladder.ByLevel.ContainsKey($tgt)) {
            [void]$skipped.Add(("the {0} build defines no '{1} +{2}'" -f $Prof.Name, $a.Family, $tgt))
            continue
        }
        if ($tgt -eq $a.Level) {
            [void]$skipped.Add(('{0} is already +{1}' -f $a.Family, $a.Level))
            continue
        }
        $newId = [int]$ladder.ByLevel[$tgt]
        if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Goods -Id $newId)) {
            [void]$skipped.Add(("'{0} +{1}' (id {2}) does not exist in the base game - refused under -BaseGame" -f $a.Family, $tgt, $newId))
            continue
        }
        $note = if ($tgt -lt $lvl) { ' (top of its ladder)' } else { '' }
        [void]$targets.Add([pscustomobject]@{ A = $a; Level = $tgt; Id = $newId })
        # A spirit ash is a good, so its level lives in the id carried by the handle.
        [void]$edits.Add((New-ErEdit -Offset $a.Offset -Old ([uint32](2952790016 + $a.ItemId)) `
            -New ([uint32](2952790016 + $newId)) -Label ('{0}  +{1} -> +{2}{3}' -f $a.Family, $a.Level, $tgt, $note)))
    }
    Write-ErLeftAlone -Reasons @($skipped)
    if (-not $edits.Count) { return }

    if (Invoke-ErSaveWriteBatch -Session $Session -Bytes $Bytes -Entry $State.Char.Entry -Edits @($edits)) {
        foreach ($t in $targets) {
            $t.A.ItemId = $t.Id
            $t.A.Level  = $t.Level
            $t.A.Name   = $(if ($State.GoodsN.ContainsKey($t.Id)) { $State.GoodsN[$t.Id] } else { $t.A.Name })
        }
    }
}

function Invoke-ErRunesAction {
    <#  Set the runes in hand.

        Rune memory (the lifetime total) is offered as a second write when the new
        balance would exceed it, rather than folded into the first: every write in this
        tool is one confirmed u32, and quietly changing a second field under a
        confirmation that named only the first would break that.  #>
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $p = $State.Player
    if ($null -eq $p) {
        Write-Host '  No player block was located in this slot, so the rune counter cannot be edited. Everything else still works.'
        return
    }

    $max = Get-ErMaxRunes
    Write-Host ("`n  RUNES   level {0}, holding {1:N0}, rune memory {2:N0}" -f $p.Level, $p.Runes, $p.RuneMemory)
    $n = Read-ErInt -Prompt '  Runes in hand' -Min 0 -Max $max
    if ($null -eq $n) { return }
    if ($n -eq $p.Runes) { Write-Host '  Already holding that many.'; return }

    $ok = Invoke-ErSaveWrite -Session $Session -Bytes $Bytes -Entry $State.Char.Entry `
              -Offset $p.RunesOffset -Old ([uint32]$p.Runes) -New ([uint32]$n) `
              -Label ('runes  {0:N0} -> {1:N0}' -f $p.Runes, $n)
    if (-not $ok) { return }
    $p.Runes = [int64]$n

    # The game never writes a save holding more runes than were ever earned, so leaving
    # memory below the new balance would be a state it does not produce.
    if ($n -gt $p.RuneMemory) {
        Write-Host ("`n  Rune memory ({0:N0}, the lifetime total) is now below what is held." -f $p.RuneMemory)
        if (Read-ErYesNo -Question '  Raise it to match?' -DefaultYes) {
            $ok2 = Invoke-ErSaveWrite -Session $Session -Bytes $Bytes -Entry $State.Char.Entry `
                       -Offset $p.MemoryOffset -Old ([uint32]$p.RuneMemory) -New ([uint32]$n) `
                       -Label ('rune memory  {0:N0} -> {1:N0}' -f $p.RuneMemory, $n)
            if ($ok2) { $p.RuneMemory = [int64]$n }
        }
    }
}

function Invoke-ErGoodsAction {
    <#  Set the stack quantity on one goods record or on a whole tick-list of them. One
        quantity applies to all of them: "999 of each of these forty" is the thing worth
        doing in bulk, and a per-item quantity in bulk would just be the serial edit
        again with more steps.  #>
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $picked = Get-ErPicked (Select-ErFromList -Title 'GOODS (key items and upgrade materials included)' `
             -Items $State.Goods -PageSize $PageSize -Multi -Label {
        param($x) '{0,-38} x{1,-5} a{2}  id {3}' -f `
            $x.Display, $x.Quantity, $x.Array, $x.ItemId
    })
    if (-not $picked.Count) { return }

    $usable  = New-Object Collections.ArrayList
    $reasons = New-Object Collections.ArrayList
    foreach ($g in $picked) {
        if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Goods -Id $g.ItemId)) {
            # Existence is asked of the param tables, never of the name: a mod leaves
            # stale vanilla names on ids the base game never defined.
            [void]$reasons.Add(('{0} (id {1}) does not exist in the base game - refused under -BaseGame' -f $g.Display, $g.ItemId))
            continue
        }
        [void]$usable.Add($g)
    }
    Write-ErLeftAlone -Reasons @($reasons)
    if (-not $usable.Count) { return }

    $prompt = if ($usable.Count -eq 1) { "  Quantity for '{0}' (now {1})" -f $usable[0].Display, $usable[0].Quantity }
              else                     { '  Quantity for all {0} selected record(s)' -f $usable.Count }
    $q = Read-ErInt -Prompt $prompt -Min 1 -Max 999
    if ($null -eq $q) { return }

    $edits   = New-Object Collections.ArrayList
    $targets = New-Object Collections.ArrayList
    $skipped = New-Object Collections.ArrayList
    foreach ($g in $usable) {
        if ($q -eq $g.Quantity) {
            [void]$skipped.Add(('{0} is already x{1}' -f $g.Display, $g.Quantity))
            continue
        }
        [void]$targets.Add($g)
        # Quantity always sits at handle+4, so this offset is phase-independent.
        [void]$edits.Add((New-ErEdit -Offset ($g.Offset + 4) -Old ([uint32]$g.Quantity) -New ([uint32]$q) `
            -Label ('{0}  x{1} -> x{2}' -f $g.Display, $g.Quantity, $q)))
    }
    Write-ErLeftAlone -Reasons @($skipped)
    if (-not $edits.Count) { return }

    if (Invoke-ErSaveWriteBatch -Session $Session -Bytes $Bytes -Entry $State.Char.Entry -Edits @($edits)) {
        foreach ($g in $targets) { $g.Quantity = $q }
    }
}

# ==============================================================================
#  Session
# ==============================================================================

if (-not (Test-ErInteractive)) {
    throw 'Edit-ErSave.ps1 is interactive and stdin is redirected. Use Show-ErEquipment / Show-ErInventory / Edit-ErUpgrade / Edit-ErItemQuantity for scripted work.'
}
Assert-ErGameNotRunning

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame
$bytes   = [IO.File]::ReadAllBytes($session.SavePath)
$prof    = $session.Profile
$vanilla = if ($BaseGame) { Get-ErProfile -Profile vanilla } else { $null }

$chars = @(Resolve-ErCharacters -Bytes $bytes -Character $Character -Slot $Slot)
$state = Open-ErSlot -Bytes $bytes -Char $chars[0] -Prof $prof -Vanilla $vanilla
if ($null -eq $state) {
    throw 'Refusing to start under -BaseGame - see the list above. Drop the flag to edit this character.'
}

$menu = @(
    [pscustomobject]@{ Key = 'weapon'; Text = 'Weapons - set reinforcement level (one or many)' }
    [pscustomobject]@{ Key = 'ash';    Text = 'Spirit ashes - set level (one or many)' }
    [pscustomobject]@{ Key = 'goods';  Text = 'Goods - set stack quantity, one or many (key items and upgrade materials included)' }
    [pscustomobject]@{ Key = 'runes';  Text = 'Runes - set the count carried in hand' }
    [pscustomobject]@{ Key = 'char';   Text = 'Change character' }
    [pscustomobject]@{ Key = 'quit';   Text = 'Quit' }
)

while ($true) {
    $c = $state.Char
    Write-Host ("`n{0}" -f ('=' * 72))
    Write-Host ("slot {0} '{1}'   checksum {2}" -f $c.Index, $c.Name,
        $(if (Test-ErChecksum -Bytes $bytes -Entry $c.Entry) { 'OK' } else { 'BAD' }))
    Write-Host ("{0} weapon(s), {1} spirit ash(es), {2} goods record(s)" -f `
        $state.Weapons.Count, $state.Ashes.Count, $state.Goods.Count)
    if ($null -ne $state.Player) {
        Write-Host ("level {0}   runes in hand {1:N0}   rune memory {2:N0}" -f `
            $state.Player.Level, $state.Player.Runes, $state.Player.RuneMemory)
    } else {
        Write-Host 'level/runes: player block not located in this slot'
    }
    # a0/a1/... on each row refer to these. The largest array is normally the held
    # inventory; the smaller ones are key items and the storage box, and the box mirrors
    # held items, so one name can appear in two of them.
    Write-Host ('arrays: ' + (@(0..($state.Arrays.Count - 1) | ForEach-Object {
        'a{0}={1} records' -f $_, $state.Arrays[$_].Count }) -join '  '))

    $pick = Select-ErOption -Prompt 'What would you like to change?' -Options $menu -AllowEscape `
                -Label { param($m) $m.Text }

    # Esc could be an accident, so it asks; picking Quit from the menu is deliberate and
    # is not second-guessed. Handled before the switch: break inside a switch statement
    # leaves the switch, not the loop.
    if ($null -eq $pick) {
        if (Read-ErYesNo -Question "`nQuit?") { break }
        continue
    }
    if ($pick.Key -eq 'quit') { break }

    switch ($pick.Key) {
        'weapon' { Invoke-ErWeaponAction -Session $session -Bytes $bytes -State $state -Prof $prof -Vanilla $vanilla -PageSize $PageSize }
        'ash'    { Invoke-ErAshAction    -Session $session -Bytes $bytes -State $state -Prof $prof -Vanilla $vanilla -PageSize $PageSize }
        'goods'  { Invoke-ErGoodsAction  -Session $session -Bytes $bytes -State $state -Prof $prof -Vanilla $vanilla -PageSize $PageSize }
        'runes'  { Invoke-ErRunesAction  -Session $session -Bytes $bytes -State $state -Prof $prof -Vanilla $vanilla -PageSize $PageSize }
        'char'   {
            $all = @(Get-ErCharacters -Bytes $bytes | Where-Object { $_.IsOccupied })
            $n = Select-ErOption -Prompt 'Which character?' -Options $all -AllowEscape `
                     -Label { param($x) 'slot {0}  {1}' -f $x.Index, $x.Name }
            if ($null -ne $n -and $n.Index -ne $state.Char.Index) {
                $loaded = Open-ErSlot -Bytes $bytes -Char $n -Prof $prof -Vanilla $vanilla
                # A refusal keeps the character already loaded rather than ending the
                # session: the user can still work on the one that passed the gate.
                if ($null -ne $loaded) { $state = $loaded }
            }
        }
    }
}

if ($script:ErBackup) { Write-Host "`nBackup from the start of this session: $script:ErBackup" }
else                  { Write-Host "`nNothing was written." }
