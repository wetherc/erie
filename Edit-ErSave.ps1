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
    [int]$PageSize = 20
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

# One backup per session, taken lazily before the first write. Held here rather than
# passed around because "have we backed up yet" is a property of the run, not of a write.
$script:ErBackup = $null

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

        The numbers are positions in the WHOLE list, not in the current page, so a given
        item keeps the same number however the list is filtered or paged. Renumbering per
        page is how a mis-click edits the wrong sword.

        Returns the chosen item, or $null for Esc.  #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Label,
        [int]$PageSize = 20
    )
    if (-not $Items.Count) {
        Write-Host "`n  $Title - none held."
        [void](Read-ErLine -Prompt '  (Enter to go back)')
        return $null
    }
    $labels = @(0..($Items.Count - 1) | ForEach-Object { & $Label $Items[$_] })
    $filter = ''
    $page   = 0

    while ($true) {
        $shown = @(0..($Items.Count - 1) | Where-Object { -not $filter -or $labels[$_] -like "*$filter*" })
        if (-not $shown.Count) {
            Write-Host ("`n  {0}: nothing matches '{1}'." -f $Title, $filter)
            $filter = ''; $page = 0
            continue
        }
        $pages = [Math]::Ceiling($shown.Count / $PageSize)
        if ($page -ge $pages) { $page = 0 }
        if ($page -lt 0)      { $page = $pages - 1 }

        Write-Host ("`n  {0}  -  {1} item(s){2}  -  page {3}/{4}" -f `
            $Title, $shown.Count, $(if ($filter) { " matching '$filter'" } else { '' }), ($page + 1), $pages)
        $from = $page * $PageSize
        $to   = [Math]::Min($from + $PageSize, $shown.Count) - 1
        foreach ($k in $from..$to) {
            Write-Host ("    [{0,4}] {1}" -f $shown[$k], $labels[$shown[$k]])
        }
        Write-Host '    number = pick | Enter = next page | p = previous | /text = filter | / = clear | Esc = back'

        $a = Read-ErLine -Prompt '  >'
        if ($null -eq $a) { return $null }
        $a = $a.Trim()
        if ($a -eq '')          { $page++ ; continue }
        if ($a -eq 'p')         { $page-- ; continue }
        if ($a.StartsWith('/')) { $filter = $a.Substring(1).Trim(); $page = 0; continue }
        if ($a -match '^\d+$') {
            $n = [int]$a
            if ($shown -contains $n) { return $Items[$n] }
            Write-Host '    That number is not in the list above (filtered out, or out of range).'
            continue
        }
        Write-Host "    Not understood. To search, start with '/'."
    }
}

# ==============================================================================
#  Writing
# ==============================================================================

function Invoke-ErSaveWrite {
    <#  Confirm, back up, write four bytes, and prove it landed.

        Proving it means re-reading the file from disk and checking both the value at the
        offset and EVERY entry checksum: a good checksum on the edited slot says nothing
        about whether the write went where it was meant to go.

        A failed verification stops the session rather than returning: continuing to edit
        a file that did not come back as expected is how one bad write becomes five.

        Returns $true if written, $false if the user declined.  #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][uint32]$Old,
        [Parameter(Mandatory)][uint32]$New,
        [Parameter(Mandatory)][string]$Label
    )
    # Not just at startup: a REPL session lasts long enough for the game to be launched
    # halfway through, and anything written while it runs is discarded when it quits.
    Assert-ErGameNotRunning

    $cur = [BitConverter]::ToUInt32($Bytes, $Offset)
    if ($cur -ne $Old) {
        throw ("Offset 0x{0:x} holds {1}, expected {2} - refusing to write. The in-memory view no longer matches the file." -f $Offset, $cur, $Old)
    }

    Write-Host ("`n  WRITE  {0}" -f $Label)
    Write-Host ("         0x{0:x}  {1} -> {2}" -f $Offset, $Old, $New)
    if (-not (Read-ErYesNo -Question '  Apply this?')) {
        Write-Host '  Left alone.'
        return $false
    }

    if (-not $script:ErBackup) {
        $script:ErBackup = "$($Session.SavePath).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item -LiteralPath $Session.SavePath -Destination $script:ErBackup
        Write-Host "  Backup -> $script:ErBackup"
    }

    [Array]::Copy([BitConverter]::GetBytes($New), 0, $Bytes, $Offset, 4)
    Update-ErChecksum -Bytes $Bytes -Entry $Entry
    [IO.File]::WriteAllBytes($Session.SavePath, $Bytes)

    $back = [IO.File]::ReadAllBytes($Session.SavePath)
    $got  = [BitConverter]::ToUInt32($back, $Offset)
    if ($got -ne $New) {
        throw ("VERIFY FAILED: 0x{0:x} reads {1} after writing {2}. Restore from {3}." -f $Offset, $got, $New, $script:ErBackup)
    }
    $entries = @(Get-ErEntries -Bytes $back)
    $bad = @($entries | Where-Object { -not (Test-ErChecksum -Bytes $back -Entry $_) })
    if ($bad.Count) {
        throw ("VERIFY FAILED: bad checksum on {0}. Restore from {1}." -f (($bad | ForEach-Object { $_.Name }) -join ', '), $script:ErBackup)
    }
    Write-Host ("  Written and verified ({0} entry checksums ok)." -f $entries.Count)
    $true
}

# ==============================================================================
#  Actions
# ==============================================================================

function Invoke-ErWeaponAction {
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $w = Select-ErFromList -Title 'WEAPONS' -Items $State.Weapons -PageSize $PageSize -Label {
        param($x)
        $cap = if ($null -ne $x.MaxLevel) { "/$($x.MaxLevel)" } else { '/?' }
        '{0,-38} +{1}{2,-5} a{3}  id {4}' -f `
            $x.Display, $x.Level, $cap, $x.Array, $x.ParamId
    }
    if ($null -eq $w) { return }

    if (-not $w.Upgradeable) {
        # MaxLevel null and MaxLevel 0 are different answers: "this build has no such
        # weapon" versus "this weapon has no reinforcement path". Say which.
        if ($null -eq $w.MaxLevel) {
            Write-Host ("  {0} (id {1}) is not defined by the {2} build at all - nothing written here could be trusted to load." -f $w.Display, $w.BaseId, $Prof.Name)
        } else {
            Write-Host ("  {0} does not reinforce in the {1} build (ceiling +0) - a level on it would be a param id with no matching row." -f $w.Display, $Prof.Name)
        }
        return
    }
    if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Weapon -Id $w.BaseId)) {
        Write-Host ("  {0} (id {1}) is not a base-game weapon - refused under -BaseGame. No level survives the mod being removed if the weapon does not." -f $w.Display, $w.BaseId)
        return
    }

    $cap = Get-ErWeaponCeiling -Profile $Prof -BaseId $w.BaseId -BaseGameProfile $Vanilla
    if ($cap -le 0) {
        Write-Host ("  {0} has no reinforcement level available under the current rules." -f $w.Display)
        return
    }
    if ($Vanilla -and $cap -lt $w.MaxLevel) {
        Write-Host ("  ceiling +{0} under -BaseGame ({1} would allow +{2})." -f $cap, $Prof.Name, $w.MaxLevel)
    }

    $lvl = Read-ErInt -Prompt ("  Level for '{0}' (now +{1})" -f $w.Display, $w.Level) -Min 0 -Max $cap
    if ($null -eq $lvl) { return }
    if ($lvl -eq $w.Level) { Write-Host '  Already at that level.'; return }

    $new = [uint32]($w.BaseId + $lvl)
    $ok = Invoke-ErSaveWrite -Session $Session -Bytes $Bytes -Entry $State.Char.Entry `
              -Offset ($w.GaOffset + 4) -Old ([uint32]$w.ParamId) -New $new `
              -Label ('{0}  +{1} -> +{2}' -f $w.Display, $w.Level, $lvl)
    if ($ok) { $w.ParamId = $new; $w.Level = $lvl }
}

function Invoke-ErAshAction {
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $a = Select-ErFromList -Title 'SPIRIT ASHES' -Items $State.Ashes -PageSize $PageSize -Label {
        param($x) '{0,-38} +{1}/{2,-4} a{3}  id {4}' -f $x.Family, $x.Level, $x.MaxLevel, $x.Array, $x.ItemId
    }
    if ($null -eq $a) { return }

    if (-not $State.Ladders.ContainsKey($a.Family)) { Write-Host '  No ladder for that ash.'; return }
    $ladder = $State.Ladders[$a.Family]
    # The ladder is read out of the name table, one entry per level, so a level this
    # build simply does not define is absent here too. Never step the id arithmetically:
    # flasks and pots also carry "+N" names but step by 2.
    $levels = @($ladder.ByLevel.Keys | Sort-Object)
    Write-Host ("  '{0}' has levels: {1}" -f $a.Family, ($levels -join ', '))

    $lvl = Read-ErInt -Prompt ("  Level for '{0}' (now +{1})" -f $a.Family, $a.Level) -Min $levels[0] -Max $levels[-1]
    if ($null -eq $lvl) { return }
    if (-not $ladder.ByLevel.ContainsKey($lvl)) {
        Write-Host ("  The {0} build defines no '{1} +{2}'." -f $Prof.Name, $a.Family, $lvl)
        return
    }
    if ($lvl -eq $a.Level) { Write-Host '  Already at that level.'; return }

    $newId = [int]$ladder.ByLevel[$lvl]
    if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Goods -Id $newId)) {
        Write-Host ("  '{0} +{1}' (id {2}) does not exist in the base game - refused under -BaseGame." -f $a.Family, $lvl, $newId)
        return
    }

    # A spirit ash is a good, so its level lives in the id carried by the handle itself.
    $ok = Invoke-ErSaveWrite -Session $Session -Bytes $Bytes -Entry $State.Char.Entry `
              -Offset $a.Offset -Old ([uint32](2952790016 + $a.ItemId)) -New ([uint32](2952790016 + $newId)) `
              -Label ('{0}  +{1} -> +{2}' -f $a.Family, $a.Level, $lvl)
    if ($ok) {
        $a.ItemId = $newId
        $a.Level  = $lvl
        $a.Name   = $(if ($State.GoodsN.ContainsKey($newId)) { $State.GoodsN[$newId] } else { $a.Name })
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
    param($Session, [byte[]]$Bytes, $State, $Prof, $Vanilla, [int]$PageSize)

    $g = Select-ErFromList -Title 'GOODS (key items and upgrade materials included)' `
             -Items $State.Goods -PageSize $PageSize -Label {
        param($x) '{0,-38} x{1,-5} a{2}  id {3}' -f `
            $x.Display, $x.Quantity, $x.Array, $x.ItemId
    }
    if ($null -eq $g) { return }

    if ($Vanilla -and -not (Test-ErItemExists -Profile $Vanilla -Family Goods -Id $g.ItemId)) {
        # Existence is asked of the param tables, never of the name: a mod leaves stale
        # vanilla names on ids the base game never defined.
        Write-Host ("  id {0} does not exist in the base game - refused under -BaseGame." -f $g.ItemId)
        return
    }

    $q = Read-ErInt -Prompt ("  Quantity for '{0}' (now {1})" -f $g.Display, $g.Quantity) -Min 1 -Max 999
    if ($null -eq $q) { return }
    if ($q -eq $g.Quantity) { Write-Host '  Already at that quantity.'; return }

    # Quantity always sits at handle+4, so this offset is phase-independent.
    $ok = Invoke-ErSaveWrite -Session $Session -Bytes $Bytes -Entry $State.Char.Entry `
              -Offset ($g.Offset + 4) -Old ([uint32]$g.Quantity) -New ([uint32]$q) `
              -Label ('{0}  x{1} -> x{2}' -f $g.Display, $g.Quantity, $q)
    if ($ok) { $g.Quantity = $q }
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
    [pscustomobject]@{ Key = 'weapon'; Text = 'Weapons - set reinforcement level' }
    [pscustomobject]@{ Key = 'ash';    Text = 'Spirit ashes - set level' }
    [pscustomobject]@{ Key = 'goods';  Text = 'Goods - set stack quantity (key items and upgrade materials included)' }
    [pscustomobject]@{ Key = 'runes';  Text = 'Runes - set the count carried in hand' }
    [pscustomobject]@{ Key = 'char';   Text = 'Change character' }
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

    if ($null -eq $pick) {
        if (Read-ErYesNo -Question "`nQuit?") { break }
        continue
    }

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
