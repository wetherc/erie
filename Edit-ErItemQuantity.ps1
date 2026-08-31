<#
.SYNOPSIS
  Sets the stack quantity of existing inventory items for a named character.
.DESCRIPTION
  Dry run by default; pass -Apply to write. On -Apply a timestamped backup is made
  next to the save first, the affected slot's MD5 is recomputed, and the result is
  re-verified before returning.

  The target character MUST be named (-Character) or its slot given (-Slot). With
  neither, the script asks rather than guessing: slot numbers are meaningless without
  the name attached, and editing the wrong character is the single easiest mistake here.

  ONLY edits items that already exist. It never adds records, so the element count,
  inventory_index allocation and acquisition tables are all left untouched. This is
  what makes it safe. See SAVE-FORMAT.md section 11.3 for why adding is not.

  With -BaseGame, an item whose id does not exist in base-game Elden Ring is refused
  rather than edited: the point of the flag is that the save stays loadable without the
  mod, and a quantity on an id the base game has never heard of does not survive that.

  CLOSE THE GAME FIRST. Quitting Elden Ring rewrites the save and would discard edits.
.EXAMPLE
  .\Edit-ErItemQuantity.ps1 -Save ER0000.cnv -Character Frieren -ItemId 10101,10105 -Quantity 999 -Apply
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
    [int[]]$ItemId,
    [string]$NameLike,
    [Parameter(Mandatory)][ValidateRange(1, 999)][int]$Quantity,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

if ($Apply) { Assert-ErGameNotRunning }
if (-not $ItemId -and -not $NameLike) { throw 'Specify -ItemId and/or -NameLike so the selection is explicit.' }

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame

$bytes   = [IO.File]::ReadAllBytes($session.SavePath)
$names   = Get-ErNameTable -Family Goods -Profile $session.Profile
$vanilla = if ($BaseGame) { Get-ErProfile -Profile vanilla } else { $null }

$target = @(Resolve-ErCharacters -Bytes $bytes -Character $Character -Slot $Slot)
Write-Host ("`nEditing: {0}" -f (($target | ForEach-Object { "'{0}' (slot {1})" -f $_.Name, $_.Index }) -join ', '))

# --- patch --------------------------------------------------------------------
$touched = @{}
$changes = 0
$refused = 0

foreach ($c in $target) {
    $entry = $c.Entry
    # The -BaseGame startup gate, per character: -Character can select several, and one
    # modded character is enough to make the whole run mean something other than it says.
    if ($vanilla -and -not (Test-ErBaseGameSafe -Bytes $bytes -Char $c -Vanilla $vanilla)) {
        throw "Refusing to run under -BaseGame on '$($c.Name)' - see the list above."
    }
    foreach ($inv in @(Find-ErInventories -Bytes $bytes -Entry $entry)) {
        foreach ($it in Get-ErInventoryItems -Bytes $bytes -Inventory $inv) {
            if ($ItemId -and $it.ItemId -notin $ItemId) { continue }
            $n = if ($it.IsGoods -and $names.ContainsKey($it.ItemId)) { $names[$it.ItemId] } else { "<id $($it.ItemId)>" }
            if ($NameLike -and $n -notlike $NameLike) { continue }

            # Existence is asked of the param tables, never of the names: a mod leaves
            # stale vanilla names on ids the base game never defined, so a name here
            # proves nothing about whether the base game can load the record.
            if ($vanilla -and $it.IsGoods -and -not (Test-ErItemExists -Profile $vanilla -Family Goods -Id $it.ItemId)) {
                Write-Host ("  SKIP  {0}: {1} (id {2}) does not exist in the base game - refused under -BaseGame" -f $c.Name, $n, $it.ItemId)
                $refused++
                continue
            }
            if ($it.Quantity -eq $Quantity) { Write-Host ("  ok    {0}: {1} already {2}" -f $c.Name, $n, $Quantity); continue }

            Write-Host ("  PATCH {0}: {1} : {2} -> {3}   (0x{4:x})" -f $c.Name, $n, $it.Quantity, $Quantity, $it.Offset)
            if ($Apply) {
                # quantity always sits at handle+4, so this is phase-independent
                [Array]::Copy([BitConverter]::GetBytes([uint32]$Quantity), 0, $bytes, $it.Offset + 4, 4)
                $touched[$entry.Index] = $entry
            }
            $changes++
        }
    }
}

if ($refused) { Write-Host ("`n{0} item(s) refused under -BaseGame. Drop the flag to edit them." -f $refused) }
if (-not $changes) {
    if ($refused) { Write-Host "`nNothing edited - every match was refused under -BaseGame." }
    else          { Write-Host "`nNo matching items found on the selected character." }
    return
}
if (-not $Apply) { Write-Host "`n(dry run - nothing written; add -Apply)"; return }
if (-not $touched.Count) { Write-Host "`nNothing needed changing."; return }

$backup = "$($session.SavePath).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -LiteralPath $session.SavePath -Destination $backup
Write-Host "`nBackup: $backup"

foreach ($e in $touched.Values) {
    Update-ErChecksum -Bytes $bytes -Entry $e
    Write-Host "Checksum updated: $($e.Name)"
}
[IO.File]::WriteAllBytes($session.SavePath, $bytes)
Write-Host "Wrote $($session.SavePath) ($changes change(s))"

$verify = [IO.File]::ReadAllBytes($session.SavePath)
$bad = @(Get-ErEntries -Bytes $verify | Where-Object { -not (Test-ErChecksum -Bytes $verify -Entry $_) })
if ($bad) { throw "VERIFY FAILED for: $($bad.Name -join ', ') - restore from $backup" }
Write-Host 'Verified: all 12 entry checksums valid.'
