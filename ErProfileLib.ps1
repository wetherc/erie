<#
  ErProfileLib.ps1: which GAME BUILD a save belongs to, and what that build allows.

  A "profile" is one set of reference tables under data/<profile>/: what item ids exist,
  what they are called, and how far each weapon upgrades. Base-game Elden Ring and The
  Convergence disagree on all three, so every read and every write has to be interpreted
  against the right one.

    vanilla      base game + DLC, read from the game's own archives
    convergence  The Convergence, read from the mod's msgbnd and regulation.bin

  Regenerate either with Export-ErNames.ps1 and Export-ErParamData.ps1.

  Dot-source this: . "$PSScriptRoot\ErProfileLib.ps1"
#>
Set-StrictMode -Version 2

# The mod renames the save file rather than relocating it. See mod/altsaves.toml, which
# sets extension = ".cnv" (and ".cnv.co2" under Seamless Co-op). That makes the extension
# the most direct evidence of which build wrote a save.
$script:ErModSaveExtensions = @('.cnv', '.co2')

# Where Convergence is usually unpacked. Only used to notice the mod is installed at all;
# nothing breaks if it is somewhere else, and -ModDir overrides.
$script:ErDefaultModDirs = @('D:\ConvergenceER', 'C:\ConvergenceER', 'E:\ConvergenceER')

# What Esc raises where the caller has not asked to handle it itself. Phrased for a user
# rather than as a sentinel, because on the non-interactive scripts this IS the message
# they see; the REPL passes -AllowEscape and never reaches it.
$script:ErCancelled = 'Cancelled.'

# Only warn once per session that this host cannot read single keys. See Read-ErLine.
$script:ErReadKeyWarned = $false

# ==============================================================================
#  Finding the save folder and its saves
# ==============================================================================

function Find-ErSaveFolder {
    <#  Elden Ring keeps saves in %APPDATA%\EldenRing\<steamId64>\. Returns every such
        folder that actually contains a save, newest-modified first, so a caller can use
        the single hit without asking or present the list when there is more than one.  #>
    param([string]$Root = (Join-Path $env:APPDATA 'EldenRing'))

    if (-not (Test-Path $Root)) { return @() }
    @(Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $saves = @(Get-ErSaveFiles -Folder $_.FullName)
            if (-not $saves.Count) { return }
            [pscustomobject]@{
                Path      = $_.FullName
                SteamId   = $_.Name
                SaveCount = $saves.Count
                Latest    = ($saves | Sort-Object LastWriteTime -Descending)[0].LastWriteTime
            }
        } | Sort-Object Latest -Descending)
}

function Get-ErSaveFiles {
    <#  The live saves in a folder, newest first.

        Backups are excluded. This toolkit writes .bak-<timestamp> copies beside the
        save, and the game never reads them, so editing one has no effect in game.  #>
    param([Parameter(Mandatory)][string]$Folder)

    if (-not (Test-Path $Folder)) { return @() }
    @(Get-ChildItem -Path $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^ER\d+\.(sl2|cnv)(\.co2)?$' } |
        Sort-Object LastWriteTime -Descending)
}

# ==============================================================================
#  Profile selection
# ==============================================================================

function Find-ErModDir {
    <#  The Convergence install, if there is one. -ModDir wins; otherwise the usual
        unpack locations are tried.  #>
    param([string]$ModDir)

    if ($ModDir) {
        if (Test-Path (Join-Path $ModDir 'mod\regulation.bin')) { return $ModDir }
        return $null
    }
    foreach ($d in $script:ErDefaultModDirs) {
        if (Test-Path (Join-Path $d 'mod\regulation.bin')) { return $d }
    }
    $null
}

function Get-ErModSaveExtension {
    <#  The extension the mod redirects ITS saves to, from mod/altsaves.toml, or $null
        if the mod is absent or is not redirecting.

        This is how '.sl2' comes to mean "base game" and not just "not obviously the
        mod". While altsaves is set, the mod cannot be writing .sl2 files, so any .sl2 in
        the save folder belongs to the unmodded game. Without altsaves the mod writes
        .sl2 too and the extension proves nothing; hence reading the file rather than
        assuming.  #>
    param([string]$ModDir)

    $dir = Find-ErModDir -ModDir $ModDir
    if (-not $dir) { return $null }
    $toml = Join-Path $dir 'mod\altsaves.toml'
    if (-not (Test-Path $toml)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($toml)) {
        if ($line -match '^\s*extension\s*=\s*"([^"]+)"') {
            $e = $Matches[1]
            if ($e -notmatch '^\.') { $e = ".$e" }
            return $e
        }
    }
    $null
}

function Test-ErModInstalled {
    <#  True if a Convergence install can be found. Used only to pick a DEFAULT; the save
        file's own extension is stronger evidence and wins where the two disagree.  #>
    param([string]$ModDir)

    [bool](Find-ErModDir -ModDir $ModDir)
}

function Resolve-ErProfile {
    <#  Decides which profile a save should be read against, and says why.

        Order of evidence:
          1. -ForceProfile, if the caller has already made the decision
          2. the save's extension: .cnv / .cnv.co2 means the mod's altsaves wrote it
          3. the mod's altsaves.toml: while it redirects mod saves to some other
             extension, a .sl2 CANNOT be a mod save, so it is a base-game one
          4. whether a Convergence install is present at all

        The reason is carried back so the tool can show it. Silently guessing the build
        would mean silently showing the wrong item names.  #>
    param(
        [Parameter(Mandatory)][string]$SavePath,
        [string]$ForceProfile,
        [string]$ModDir
    )

    if ($ForceProfile) {
        return [pscustomobject]@{ Profile = $ForceProfile; Reason = 'requested explicitly' }
    }

    $ext = [IO.Path]::GetExtension($SavePath)
    if ($ext -in $script:ErModSaveExtensions) {
        return [pscustomobject]@{
            Profile = 'convergence'
            Reason  = "the save is a '$ext' file, which is written by the mod's altsaves setting"
        }
    }
    $modExt = Get-ErModSaveExtension -ModDir $ModDir
    if ($modExt) {
        # The mod is installed AND sending its own saves elsewhere, so it did not write
        # this file. .sl2 and .cnv sitting in one folder are two different playthroughs,
        # not two copies of one: reading the .sl2 against the mod's tables would rename
        # items that were never modded.
        return [pscustomobject]@{
            Profile = 'vanilla'
            Reason  = "the mod sends its own saves to '$modExt' (altsaves.toml), so a '$ext' file is a base-game save"
        }
    }
    if (Test-ErModInstalled -ModDir $ModDir) {
        return [pscustomobject]@{
            Profile = 'convergence'
            Reason  = 'a Convergence install was found and it is not redirecting its saves, so it writes this extension too'
        }
    }
    [pscustomobject]@{ Profile = 'vanilla'; Reason = 'no mod install found' }
}

# ==============================================================================
#  Loading a profile's tables
# ==============================================================================

function Get-ErProfile {
    <#  Loads data/<profile>/ into one object:

          Names      family -> (id -> display name)
          ParamIds   family -> HashSet[int] of ids that EXIST in this build
          MaxLevel   weapon base id -> reinforcement ceiling

        Names and ParamIds are different questions and are kept apart on purpose: a mod
        leaves stale vanilla NAMES on ids it never defined, so "has a name" is not
        evidence an item exists. Every existence test goes through ParamIds.  #>
    param(
        [Parameter(Mandatory)][ValidateSet('vanilla', 'convergence')][string]$Profile,
        [string]$DataDir = "$PSScriptRoot\data"
    )

    $dir = Join-Path $DataDir $Profile
    if (-not (Test-Path $dir)) {
        throw "No reference data for profile '$Profile' ($dir). Generate it with Export-ErNames.ps1 -Profile $Profile and Export-ErParamData.ps1 -Profile $Profile."
    }

    $names = @{}
    foreach ($fam in @('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem')) {
        $t = @{}
        $file = Join-Path $dir "$($fam.ToLower())names.tsv"
        if (Test-Path $file) {
            foreach ($line in [IO.File]::ReadAllLines($file)) {
                $f = $line.Split("`t")
                if ($f.Count -ge 2) { $t[[int]$f[0]] = $f[1] }
            }
        }
        $names[$fam] = $t
    }

    $paramIds = @{}
    foreach ($fam in @('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem')) {
        $paramIds[$fam] = New-Object 'Collections.Generic.HashSet[int]'
    }
    $idFile = Join-Path $dir 'paramids.tsv'
    if (-not (Test-Path $idFile)) {
        throw "Missing $idFile - run Export-ErParamData.ps1 -Profile $Profile."
    }
    foreach ($line in [IO.File]::ReadAllLines($idFile)) {
        $f = $line.Split("`t")
        if ($f.Count -ge 2 -and $paramIds.ContainsKey($f[0])) { [void]$paramIds[$f[0]].Add([int]$f[1]) }
    }

    $maxLevel = @{}
    $lvFile = Join-Path $dir 'weaponlevels.tsv'
    if (-not (Test-Path $lvFile)) {
        throw "Missing $lvFile - run Export-ErParamData.ps1 -Profile $Profile."
    }
    foreach ($line in [IO.File]::ReadAllLines($lvFile)) {
        $f = $line.Split("`t")
        if ($f.Count -ge 2) { $maxLevel[[int]$f[0]] = [int]$f[1] }
    }

    [pscustomobject]@{
        Name     = $Profile
        Dir      = $dir
        Names    = $names
        ParamIds = $paramIds
        MaxLevel = $maxLevel
    }
}

function Test-ErItemExists {
    <#  Does this id exist in the profile's build? The question every base-game-mode
        check reduces to.  #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][ValidateSet('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem')][string]$Family,
        [Parameter(Mandatory)][int]$Id
    )
    $Profile.ParamIds[$Family].Contains($Id)
}

function Get-ErWeaponCeiling {
    <#  The highest level THIS weapon may be written to on THIS run.

        There is no single answer like "+25" or "+10", and the mod's own item description
        text ("Strengthens armaments to +10") is simply wrong: Convergence's regulation
        puts 4654 weapons at +15. Every caller that writes a level goes through here.

        Three things can lower the ceiling and none of them can raise it:

          * the active build's ceiling for this weapon, from weaponlevels.tsv;
          * -BaseGame, which additionally clamps to what vanilla allows for this weapon.
            A weapon vanilla does not define clamps to 0, since no level survives the mod
            being removed if the weapon itself does not;
          * -MaxWeaponLevel, which means "no higher than", never "set to".

        Returns 0 for anything that cannot be reinforced, so callers can test one value
        rather than repeating the id rules that used to live in ERSaveLib.  #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][int]$BaseId,
        # -1 = not specified. 0 is a legitimate request meaning "leave everything alone".
        [int]$Requested = -1,
        # A loaded vanilla profile when -BaseGame is in force, otherwise $null.
        $BaseGameProfile
    )
    if (-not $Profile.MaxLevel.ContainsKey($BaseId)) { return 0 }
    $cap = [int]$Profile.MaxLevel[$BaseId]

    if ($BaseGameProfile) {
        if (-not $BaseGameProfile.MaxLevel.ContainsKey($BaseId)) { return 0 }
        $v = [int]$BaseGameProfile.MaxLevel[$BaseId]
        if ($v -lt $cap) { $cap = $v }
    }
    if ($Requested -ge 0 -and $Requested -lt $cap) { $cap = $Requested }
    $cap
}

function Get-ErItemName {
    <#  Display name for an id, falling back to a visible placeholder rather than an empty
        string: an unnamed row is a real thing to see in a list, not something to hide. #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][int]$Id
    )
    if ($Profile.Names[$Family].ContainsKey($Id)) {
        $n = $Profile.Names[$Family][$Id]
        if ($n -and $n -ne '[ERROR]') { return $n }
    }
    "<$($Family.ToLower()) $Id>"
}

# ==============================================================================
#  Mod-content detection
# ==============================================================================

function Get-ErKnownProfiles {
    <#  Every profile with reference data on disk, loaded, keyed by name.

        Used to attribute an id the ACTIVE profile does not define. "This is Convergence
        content, drop -BaseGame" and "this id exists in no build this toolkit knows" call
        for completely different advice, and only a cross-profile lookup can tell them
        apart.  #>
    param([string]$DataDir = "$PSScriptRoot\data")

    $out = @{}
    foreach ($p in @('vanilla', 'convergence')) {
        if (-not (Test-Path (Join-Path $DataDir $p))) { continue }
        # A profile with half its tables generated should not take the caller down with
        # it: it just cannot contribute an attribution.
        try { $out[$p] = Get-ErProfile -Profile $p -DataDir $DataDir } catch { }
    }
    $out
}

function Find-ErModdedItems {
    <#  Every item the character holds whose id does NOT exist in $Profile's build.

        This backs the message "-BaseGame refused: this save already has modded data".
        It is conservative: a false positive would block a legitimate edit,
        so anything that cannot be resolved with confidence is passed over rather than
        reported:

          * records whose handle has no GaItem entry are skipped. Some talismans store
            their param id somewhere this toolkit does not yet read (README section 4.5),
            and calling those "modded" would be an outright lie.
          * only the five families with a param table are checked.

        Each row carries a Status, because "absent from this profile" has two very
        different causes:

          OtherBuild  the id exists in another profile's tables. Real content from that
                      build; dropping -BaseGame is the fix.
          Orphan      no profile this toolkit knows defines the id. Dropping -BaseGame
                      will NOT help, so the caller must not offer that as the remedy.

        Orphans are real and expected. See SAVE-FORMAT.md section 10. An orphan is a
        well-formed inventory record that no param, no param reference and no FMG in
        either build defines. They are reported, never allowlisted.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Profile,
        $Inventories,
        $GaIndex,
        # Other loaded profiles, for attribution. Pass them in when checking several
        # characters so the tables are read once instead of once per character.
        $KnownProfiles,
        [string]$DataDir = "$PSScriptRoot\data"
    )

    if (-not $Inventories)   { $Inventories   = @(Find-ErInventories -Bytes $Bytes -Entry $Entry) }
    if (-not $GaIndex)       { $GaIndex       = Get-ErGaItemIndex -Bytes $Bytes -Entry $Entry -Inventories $Inventories }
    if (-not $KnownProfiles) { $KnownProfiles = Get-ErKnownProfiles -DataDir $DataDir }

    $seen = @{}
    foreach ($inv in $Inventories) {
        foreach ($it in (Get-ErInventoryItems -Bytes $Bytes -Inventory $inv)) {

            $family = $null; $id = $null
            if ($it.IsGoods) {
                $family = 'Goods'; $id = $it.ItemId
            }
            else {
                if (-not $GaIndex.ContainsKey($it.Handle)) { continue }   # unresolvable, see above
                $paramId = [BitConverter]::ToUInt32($Bytes, $GaIndex[$it.Handle] + 4)
                if ($it.Category -eq '0x8') {
                    $family = 'Weapon'
                    # A weapon param id is base + reinforcement level, and the affinity
                    # is part of the base: only the last two digits are the level.
                    $id = [int]($paramId - ($paramId % 100))
                }
                elseif ($it.Category -eq '0x9') {
                    $family = 'Protector'; $id = [int]($paramId -band 0x0FFFFFFF)
                }
                elseif ($it.Category -eq '0xC') {
                    $family = 'Gem'; $id = [int]($paramId -band 0x0FFFFFFF)
                }
                else { continue }   # talismans and anything else unmodelled
            }

            if (Test-ErItemExists -Profile $Profile -Family $family -Id $id) { continue }

            $key = "$family/$id"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            # Which other build, if any, does define it?
            $knownIn = @()
            $name    = $null
            foreach ($pn in $KnownProfiles.Keys) {
                if ($pn -eq $Profile.Name) { continue }
                if (-not (Test-ErItemExists -Profile $KnownProfiles[$pn] -Family $family -Id $id)) { continue }
                $knownIn += $pn
                if (-not $name) { $name = Get-ErItemName -Profile $KnownProfiles[$pn] -Family $family -Id $id }
            }
            if (-not $name) { $name = Get-ErItemName -Profile $Profile -Family $family -Id $id }

            [pscustomobject]@{
                Family  = $family
                Id      = $id
                Name    = $name
                Status  = if ($knownIn.Count) { 'OtherBuild' } else { 'Orphan' }
                KnownIn = $knownIn
                Offset  = $it.Offset
            }
        }
    }
}

function Test-ErBaseGameSafe {
    <#  The -BaseGame startup gate: may this character be edited under base-game rules at
        all? Returns $true to proceed, $false to refuse. Prints its findings unless -Quiet.

        Per-item refusal (Test-ErItemExists, already in both Edit scripts and the REPL)
        is what stops an unsafe write. This gate adds only the timing: it reports before
        the user picks their way through a menu, rather than after.

        Two findings need two verdicts, and must not be conflated:

          OtherBuild  ids that another build this toolkit knows about does define, for
                      example Convergence content in a base-game session. REFUSED, and the
                      message says to drop the flag, because dropping it is the fix.

          Orphan      ids that NO known build defines (README section 4; four of them
                      live in this author's own save). NOT refused. Dropping -BaseGame
                      would not make them editable either, so refusing here would make
                      the flag permanently unusable on that character for a reason the
                      flag cannot fix. They are reported and passed over; anything aimed
                      at one is still refused item by item.

        The flag does not remove mod content and cannot; it only restricts what this
        toolkit will write. A save full of Convergence items stays a Convergence save.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Char,
        # The vanilla profile, already loaded. Passed in rather than loaded here so a
        # multi-character run reads the tables once.
        [Parameter(Mandatory)]$Vanilla,
        $Inventories,
        $GaIndex,
        $KnownProfiles,
        # How many rows to list before summarising. A modded character can hold hundreds.
        [int]$Show = 12,
        [switch]$Quiet
    )

    $found = @(Find-ErModdedItems -Bytes $Bytes -Entry $Char.Entry -Profile $Vanilla `
                   -Inventories $Inventories -GaIndex $GaIndex -KnownProfiles $KnownProfiles)
    $other   = @($found | Where-Object { $_.Status -eq 'OtherBuild' })
    $orphans = @($found | Where-Object { $_.Status -eq 'Orphan' })

    if (-not $Quiet -and $orphans.Count) {
        Write-Host ("BASEGAME {0} item(s) on '{1}' that no known build defines. Not counted against the flag - see README section 4:" -f $orphans.Count, $Char.Name)
        foreach ($o in @($orphans | Select-Object -First $Show)) {
            Write-Host ("           {0,-10} {1,-9} {2}" -f $o.Family, $o.Id, $o.Name)
        }
        if ($orphans.Count -gt $Show) { Write-Host ("           ... and {0} more" -f ($orphans.Count - $Show)) }
    }

    if (-not $other.Count) { return $true }

    if (-not $Quiet) {
        Write-Host ("BASEGAME '{0}' holds {1} item(s) base-game Elden Ring does not define:" -f $Char.Name, $other.Count)
        foreach ($o in @($other | Select-Object -First $Show)) {
            Write-Host ("           {0,-10} {1,-9} {2}  (defined by: {3})" -f $o.Family, $o.Id, $o.Name, ($o.KnownIn -join ', '))
        }
        if ($other.Count -gt $Show) { Write-Host ("           ... and {0} more" -f ($other.Count - $Show)) }
        Write-Host '         Drop -BaseGame to edit this character. The flag restricts what gets written; it does not remove mod content already in the save.'
    }
    $false
}

# ==============================================================================
#  Session startup
# ==============================================================================
# Every entry point resolves the same four things in the same order (which folder,
# which save, which build, which character), and the REPL (Edit-ErSave.ps1) has to agree
# with them exactly, or the same arguments would select a different save depending on
# which script was run. That is why this lives here rather than being repeated per
# script.

function Test-ErInteractive {
    <#  Can we prompt? A redirected stdin means a script or a pipe is driving us, and a
        Read-Host there hangs forever instead of failing.  #>
    [bool]($Host.UI.RawUI) -and -not [Console]::IsInputRedirected
}

function Read-ErLine {
    <#  One line of input, read a key at a time so that Esc is visible.

        Read-Host cannot see Esc: it returns only on Enter and swallows the key, which
        would leave Esc working in some prompts and ignored in others. Every
        prompt in this toolkit goes through here instead, so backing out means the same
        thing everywhere.

        Returns the typed string, or $null for Esc. Backspace erases; any other control
        key is ignored rather than inserted, so an arrow key does not end up in the
        answer.

        Some hosts (the ISE among them) have no single-key reader at all. There the
        fallback is Read-Host and Esc genuinely cannot be detected, so it says so once
        instead of pretending otherwise.  #>
    param([string]$Prompt = '>')

    Write-Host "$Prompt " -NoNewline
    $buf = New-Object Text.StringBuilder
    while ($true) {
        $k = $null
        try { $k = [Console]::ReadKey($true) }
        catch {
            if (-not $script:ErReadKeyWarned) {
                $script:ErReadKeyWarned = $true
                Write-Host "`n(this host cannot read single keys, so Esc will not work here)"
            }
            return (Read-Host $Prompt)
        }
        switch ($k.Key) {
            'Escape' { Write-Host ''; return $null }
            'Enter'  { Write-Host ''; return $buf.ToString() }
            'Backspace' {
                if ($buf.Length) {
                    [void]$buf.Remove($buf.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
            }
            default {
                # KeyChar is NUL for function and arrow keys; 127 is DEL.
                $c = $k.KeyChar
                if ([int]$c -ge 32 -and [int]$c -ne 127) {
                    [void]$buf.Append($c)
                    Write-Host $c -NoNewline
                }
            }
        }
    }
}

function Read-ErYesNo {
    <#  A yes/no question. Esc counts as no: the safe answer to "shall I write this?" is
        always the one that does not write.  #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [switch]$DefaultYes
    )
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-ErLine -Prompt "$Question $suffix"
        if ($null -eq $a) { return $false }
        $a = $a.Trim()
        if (-not $a) { return [bool]$DefaultYes }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$')  { return $false }
        Write-Host '  Answer y or n.'
    }
}

function Read-ErInt {
    <#  A whole number in a range, or $null if the user pressed Esc.

        Callers MUST test with ($null -eq $x), never with (-not $x): 0 is a legitimate
        answer here (+0 is a real reinforcement level), and -not 0 is true.  #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Min,
        [Parameter(Mandatory)][int]$Max
    )
    while ($true) {
        $a = Read-ErLine -Prompt ("{0} ({1}-{2}, Esc to go back)" -f $Prompt, $Min, $Max)
        if ($null -eq $a) { return $null }
        $a = $a.Trim()
        if ($a -match '^\d+$') {
            $v = [int]$a
            if ($v -ge $Min -and $v -le $Max) { return $v }
        }
        Write-Host ("  Not a number from {0} to {1}." -f $Min, $Max)
    }
}

function Select-ErOption {
    <#  Numbered pick-one prompt. Non-interactively this throws and lists the options in
        the message, so the caller learns what to pass instead of hanging.

        Esc returns $null with -AllowEscape, and otherwise cancels the whole run. Reading
        through Read-ErLine rather than Read-Host is what makes Esc detectable.  #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object[]]$Options,
        [Parameter(Mandatory)][scriptblock]$Label,
        [string]$NonInteractiveHint,
        [switch]$AllowEscape
    )
    if ($Options.Count -eq 1) { return $Options[0] }
    $labels = @($Options | ForEach-Object { & $Label $_ })
    if (-not (Test-ErInteractive)) {
        throw ("$Prompt $NonInteractiveHint`n  " + ($labels -join "`n  "))
    }
    Write-Host "`n$Prompt"
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("   [{0}] {1}" -f $i, $labels[$i]) }
    while ($true) {
        $a = Read-ErLine -Prompt 'Number'
        if ($null -eq $a) {
            if ($AllowEscape) { return $null }
            throw $script:ErCancelled
        }
        $a = $a.Trim()
        if ($a -match '^\d+$' -and [int]$a -lt $Options.Count) { return $Options[[int]$a] }
        Write-Host 'Not one of the numbers above.'
    }
}

function Assert-ErGameNotRunning {
    <#  Elden Ring rewrites the save from memory when it exits, so anything written while
        it runs is discarded without a word. Refuse rather than lose the edit.  #>
    $p = @(Get-Process eldenring, me3, start_protected_game -ErrorAction SilentlyContinue)
    if ($p.Count) {
        throw ("Elden Ring / ME3 is running ({0}). Close the game first - quitting it rewrites the save and would discard these edits." -f (($p | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '))
    }
}

function Resolve-ErSession {
    <#  Turns the shared parameter block (-SaveFolder -Save -Path -Profile -BaseGame
        -ModDir) into a resolved session: which file, which build, and that build's
        tables loaded.

        Order of preference for the save file:
          1. -Path, an explicit file
          2. -Save, resolved inside the folder (a bare name, with or without extension)
          3. the only live save in the folder
          4. a prompt

        Backups never appear in 3 or 4 (Get-ErSaveFiles excludes them), because the game
        never reads a .bak, so editing one has no effect in game.

        The chosen profile and the reason for it are printed, not just recorded: the
        wrong build does not fail, it renames every item on screen.  #>
    param(
        [string]$Path,
        [string]$SaveFolder,
        [string]$Save,
        [string]$Profile,
        [string]$ModDir,
        [switch]$BaseGame,
        [string]$DataDir = "$PSScriptRoot\data",
        [switch]$Quiet
    )

    # --- the file ---------------------------------------------------------------
    $savePath = $null
    if ($Path) {
        $savePath = $Path
    }
    elseif ($Save -and ($Save -match '[\\/]' -or [IO.Path]::IsPathRooted($Save))) {
        $savePath = $Save
    }
    else {
        $folder = $SaveFolder
        if (-not $folder) {
            $found = @(Find-ErSaveFolder)
            if (-not $found.Count) {
                throw "No Elden Ring save folder found under $(Join-Path $env:APPDATA 'EldenRing'). Pass -SaveFolder or -Path."
            }
            $folder = (Select-ErOption -Prompt 'Which save folder?' -Options $found `
                -Label { param($f) '{0}  ({1} save(s), newest {2:yyyy-MM-dd HH:mm})' -f $f.SteamId, $f.SaveCount, $f.Latest } `
                -NonInteractiveHint 'Pass -SaveFolder with one of:').Path
        }
        if (-not (Test-Path $folder)) { throw "Save folder not found: $folder" }

        $files = @(Get-ErSaveFiles -Folder $folder)
        if (-not $files.Count) { throw "No live save files in $folder (backups are deliberately not offered)." }

        if ($Save) {
            $hit = @($files | Where-Object { $_.Name -eq $Save -or $_.BaseName -eq $Save })
            if (-not $hit.Count) {
                throw "No save named '$Save' in $folder. Present: $(($files | ForEach-Object { $_.Name }) -join ', ')"
            }
            # "ER0000" matches both ER0000.sl2 and ER0000.cnv: the base game save and the
            # mod's. Those are different characters, so never quietly take the first.
            $savePath = (Select-ErOption -Prompt "'$Save' matches more than one save. Which one?" -Options $hit `
                -Label { param($f) '{0}  (modified {1:yyyy-MM-dd HH:mm})' -f $f.Name, $f.LastWriteTime } `
                -NonInteractiveHint 'Pass -Save with the full file name:').FullName
        }
        else {
            $savePath = (Select-ErOption -Prompt 'Which save file?' -Options $files `
                -Label { param($f) '{0}  ({1:N0} bytes, modified {2:yyyy-MM-dd HH:mm})' -f $f.Name, $f.Length, $f.LastWriteTime } `
                -NonInteractiveHint 'Pass -Save with one of:').FullName
        }
    }
    if (-not (Test-Path $savePath)) { throw "Save file not found: $savePath" }

    # --- the build --------------------------------------------------------------
    $res  = Resolve-ErProfile -SavePath $savePath -ForceProfile $Profile -ModDir $ModDir
    $prof = Get-ErProfile -Profile $res.Profile -DataDir $DataDir

    if (-not $Quiet) {
        Write-Host ("SAVE     {0}" -f $savePath)
        Write-Host ("PROFILE  {0}  ({1})" -f $res.Profile, $res.Reason)
        if ($BaseGame) {
            Write-Host 'BASEGAME edits restricted to what base-game Elden Ring supports.'
            if ([IO.Path]::GetExtension($savePath) -in $script:ErModSaveExtensions) {
                # Legitimate (preparing a modded save for a return to the base game), but
                # it is worth saying out loud, because the save on disk was written by a
                # build that does not obey the rules about to be enforced on it.
                Write-Host "         NOTE: this is a mod save ($([IO.Path]::GetExtension($savePath))) being edited under base-game rules."
            }
        }
    }

    [pscustomobject]@{
        SavePath    = $savePath
        ProfileName = $res.Profile
        Reason      = $res.Reason
        Profile     = $prof
        BaseGame    = [bool]$BaseGame
        DataDir     = $DataDir
    }
}

function Resolve-ErCharacters {
    <#  The character(s) to act on: named, given by slot, or asked for.

        Never defaults to a slot. A slot number says nothing about who is in it: the
        base-game .sl2 and the Convergence .cnv both have a slot 3 and they hold
        different characters, so a default here would edit an unintended character.

        -AllowAll is for the read-only listers, where "no selection" sensibly means every
        occupied character. An edit must not take that shortcut.

        Uses ERSaveLib's Get-ErCharacters; every entry point dot-sources both files.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$Character,
        [int[]]$Slot,
        [switch]$AllowAll
    )
    $chars = @(Get-ErCharacters -Bytes $Bytes | Where-Object { $_.IsOccupied })
    if (-not $chars.Count) { throw 'This save holds no characters.' }

    if ($Character) { $Slot = @(Resolve-ErSlot -Bytes $Bytes -Character $Character) }
    # $Slot.Count, not truthiness: a single-element @(0) coerces to 0, which is false,
    # and slot 0 is a real slot. Testing truthiness sends -Slot 0 to the picker instead.
    if ($null -ne $Slot -and $Slot.Count) {
        $hit = @($chars | Where-Object { $_.Index -in $Slot })
        if (-not $hit.Count) {
            throw ("No occupied character in slot(s) {0}. Present: {1}" -f ($Slot -join ', '),
                (($chars | ForEach-Object { '{0} (slot {1})' -f $_.Name, $_.Index }) -join ', '))
        }
        return $hit
    }
    if ($AllowAll) { return $chars }

    @(Select-ErOption -Prompt 'Which character?' -Options $chars `
        -Label { param($c) 'slot {0}  {1}' -f $c.Index, $c.Name } `
        -NonInteractiveHint 'Pass -Character (or -Slot) naming one of:')
}
