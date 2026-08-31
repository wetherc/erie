<#
.SYNOPSIS
  Sets (or adds to) the runes a character is carrying.
.DESCRIPTION
  Dry run by default; pass -Apply to write. On -Apply a timestamped backup is made next
  to the save first, the affected slot's MD5 is recomputed, and every value written is
  read back from disk before the script returns.

  The target character MUST be named (-Character) or its slot given (-Slot). With
  neither, the script asks rather than guessing: slot numbers are meaningless without the
  name attached, and editing the wrong character is the single easiest mistake here.

  This edits the runes IN HAND, the counter the HUD shows, not runes dropped on death and
  not any Rune item in the inventory (those are goods - use Edit-ErItemQuantity.ps1).

  Rune memory, the lifetime total the file also tracks, is raised alongside it whenever
  the new balance would exceed it: the game never produces a save where more runes are
  held than were ever earned. Pass -SkipRuneMemory to leave it alone.

  -BaseGame is accepted so the argument block matches every other entry point, but it
  changes nothing here: a rune count is a plain number in the player block, identical
  under the base game and under Convergence, so there is nothing that could fail to load
  without the mod.

  CLOSE THE GAME FIRST. Quitting Elden Ring rewrites the save and would discard edits.
.EXAMPLE
  .\Edit-ErRunes.ps1 -Save ER0000.cnv -Character Frieren -Runes 999999999
.EXAMPLE
  .\Edit-ErRunes.ps1 -Save ER0000.cnv -Character Frieren -Runes 50000 -Add -Apply
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
    [Parameter(Mandatory)][ValidateRange(0, 999999999)][int]$Runes,
    # Treat -Runes as an amount to add to what is already held, clamped at the ceiling,
    # rather than the new balance.
    [switch]$Add,
    [switch]$SkipRuneMemory,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"

if ($Apply) { Assert-ErGameNotRunning }

$session = Resolve-ErSession -Path $Path -SaveFolder $SaveFolder -Save $Save `
                             -Profile $Profile -ModDir $ModDir -BaseGame:$BaseGame

$bytes  = [IO.File]::ReadAllBytes($session.SavePath)
$maxRunes = Get-ErMaxRunes

$target = @(Resolve-ErCharacters -Bytes $bytes -Character $Character -Slot $Slot)
Write-Host ("`nEditing: {0}" -f (($target | ForEach-Object { "'{0}' (slot {1})" -f $_.Name, $_.Index }) -join ', '))

# --- patch --------------------------------------------------------------------
# Each entry is one u32 to write. Collected first and applied together so that a
# character whose player block could not be located stops the run before anything is
# written, rather than halfway through a multi-character selection.
$writes  = New-Object Collections.ArrayList
$touched = @{}
$missing = 0

foreach ($c in $target) {
    $pd = Get-ErPlayerData -Bytes $bytes -Char $c
    if ($null -eq $pd) {
        # The block is found by a scan, so "not found" is a real outcome and not an
        # assertion failure. Say so and leave the character alone.
        Write-Host ("  SKIP  {0}: no player block matched in slot {1} - runes cannot be located, nothing written for this character." -f $c.Name, $c.Index)
        $missing++
        continue
    }

    $new = if ($Add) { [int64]$pd.Runes + $Runes } else { [int64]$Runes }
    if ($new -gt $maxRunes) {
        Write-Host ("  note  {0}: {1:N0} would exceed the game's ceiling; capped at {2:N0}." -f $c.Name, $new, $maxRunes)
        $new = [int64]$maxRunes
    }

    Write-Host ("  {0}: level {1}, holding {2:N0} rune(s), rune memory {3:N0}" -f $c.Name, $pd.Level, $pd.Runes, $pd.RuneMemory)
    if ($new -eq $pd.Runes) {
        Write-Host ("  ok    {0}: already holding {1:N0}" -f $c.Name, $new)
    }
    else {
        Write-Host ("  PATCH {0}: runes {1:N0} -> {2:N0}   (0x{3:x})" -f $c.Name, $pd.Runes, $new, $pd.RunesOffset)
        [void]$writes.Add([pscustomobject]@{ Entry = $c.Entry; Offset = $pd.RunesOffset; Value = [uint32]$new })
    }

    if (-not $SkipRuneMemory -and $new -gt $pd.RuneMemory) {
        Write-Host ("  PATCH {0}: rune memory {1:N0} -> {2:N0}   (0x{3:x})" -f $c.Name, $pd.RuneMemory, $new, $pd.MemoryOffset)
        [void]$writes.Add([pscustomobject]@{ Entry = $c.Entry; Offset = $pd.MemoryOffset; Value = [uint32]$new })
    }
}

if ($missing -and -not $writes.Count) { Write-Host "`nNothing edited - no player block was located."; return }
if (-not $writes.Count) { Write-Host "`nNothing needed changing."; return }
if (-not $Apply) { Write-Host "`n(dry run - nothing written; add -Apply)"; return }

$backup = "$($session.SavePath).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -LiteralPath $session.SavePath -Destination $backup
Write-Host "`nBackup: $backup"

foreach ($w in $writes) {
    [Array]::Copy([BitConverter]::GetBytes($w.Value), 0, $bytes, $w.Offset, 4)
    $touched[$w.Entry.Index] = $w.Entry
}
foreach ($e in $touched.Values) {
    Update-ErChecksum -Bytes $bytes -Entry $e
    Write-Host "Checksum updated: $($e.Name)"
}
[IO.File]::WriteAllBytes($session.SavePath, $bytes)
Write-Host "Wrote $($session.SavePath) ($($writes.Count) value(s))"

# Verify from disk: every value at the offset it was meant for, and every checksum. A
# good checksum on the edited slot says nothing about whether the write landed where it
# was meant to.
$verify = [IO.File]::ReadAllBytes($session.SavePath)
foreach ($w in $writes) {
    $got = [BitConverter]::ToUInt32($verify, $w.Offset)
    if ($got -ne $w.Value) {
        throw ("VERIFY FAILED: 0x{0:x} reads {1} after writing {2} - restore from {3}" -f $w.Offset, $got, $w.Value, $backup)
    }
}
$bad = @(Get-ErEntries -Bytes $verify | Where-Object { -not (Test-ErChecksum -Bytes $verify -Entry $_) })
if ($bad) { throw "VERIFY FAILED for: $($bad.Name -join ', ') - restore from $backup" }
Write-Host 'Verified: values read back and all 12 entry checksums valid.'
