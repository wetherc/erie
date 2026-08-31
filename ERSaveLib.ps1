<#
  ERSaveLib.ps1: shared helpers for Elden Ring .sl2 / .cnv save files.
  Dot-source this: . "C:\Users\chris\ERSaveTools\ERSaveLib.ps1"
  See README.md for the format notes these functions rely on.
#>
Set-StrictMode -Version 2

# --- BND4 container -----------------------------------------------------------

function Get-ErEntries {
    <#  Parses the BND4 entry table. Entry headers start at 0x40, 32 bytes each:
        +0  flags (u64)   +8  size (u64)   +16 dataOffset (u32)   +20 nameOffset (u32)  #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'BND4') { throw 'Not a BND4 container' }
    $count = [BitConverter]::ToInt32($Bytes, 12)
    for ($i = 0; $i -lt $count; $i++) {
        $o = 0x40 + $i * 32
        $nameOff = [BitConverter]::ToInt32($Bytes, $o + 20)
        $sb = New-Object Text.StringBuilder
        $p = $nameOff
        while ($true) {
            $c = [BitConverter]::ToUInt16($Bytes, $p)
            if ($c -eq 0) { break }
            [void]$sb.Append([char]$c); $p += 2
        }
        [pscustomobject]@{
            Index      = $i
            Name       = $sb.ToString()
            Size       = [BitConverter]::ToInt64($Bytes, $o + 8)
            DataOffset = [BitConverter]::ToInt32($Bytes, $o + 16)
        }
    }
}

# --- Per-entry MD5 ------------------------------------------------------------
# Each entry payload is: [16-byte MD5 of everything after it][data].
# Any edit to an entry MUST be followed by Update-ErChecksum or the game rejects the slot.

function Test-ErChecksum {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$Entry)
    $rest = New-Object byte[] ($Entry.Size - 16)
    [Array]::Copy($Bytes, $Entry.DataOffset + 16, $rest, 0, $rest.Length)
    $calc = [Security.Cryptography.MD5]::Create().ComputeHash($rest)
    for ($i = 0; $i -lt 16; $i++) { if ($calc[$i] -ne $Bytes[$Entry.DataOffset + $i]) { return $false } }
    $true
}

function Update-ErChecksum {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$Entry)
    $rest = New-Object byte[] ($Entry.Size - 16)
    [Array]::Copy($Bytes, $Entry.DataOffset + 16, $rest, 0, $rest.Length)
    $calc = [Security.Cryptography.MD5]::Create().ComputeHash($rest)
    [Array]::Copy($calc, 0, $Bytes, $Entry.DataOffset, 16)
}

# --- Inventory ----------------------------------------------------------------
# Record = { u32 ga_item_handle; u32 quantity; u32 inventory_index }  (12 bytes)
# A u32 element count sits immediately BEFORE the first record.
# Handle top nibble encodes category; goods are 0xB0000000 | goodsId.

function Test-ErHandle {
    param([byte[]]$Bytes, [int64]$Pos)
    $h = [BitConverter]::ToUInt32($Bytes, $Pos)
    if ($h -eq 0) { return $false }
    $n = $h -shr 28
    ($n -eq 1 -or $n -eq 2 -or $n -eq 4 -or $n -eq 8 -or $n -eq 9 -or $n -eq 10 -or $n -eq 11 -or $n -eq 12)
}

# The candidate scan below is byte-aligned and therefore runs ~4x more probes than a
# 4-aligned one. Pure PowerShell takes minutes per slot, so the inner loop is compiled
# once into a helper type. Guarded because dot-sourcing twice would otherwise throw.
if (-not ('ErSaveScan' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;

public static class ErSaveScan
{
    public struct Cand { public int CountOffset, ArrayStart, Count, Live; public long ArrayEnd; }

    static bool IsHandle(byte[] b, int q)
    {
        uint h = BitConverter.ToUInt32(b, q);
        if (h == 0) return false;
        uint n = h >> 28;
        return n == 1 || n == 2 || n == 4 || n == 8 || n == 9 || n == 10 || n == 11 || n == 12;
    }

    public static List<Cand> Find(byte[] b, int start, int end, int minCount, int maxCount)
    {
        var outp = new List<Cand>();
        for (int p = start; p < end - 64; p++)
        {
            uint n = BitConverter.ToUInt32(b, p);
            if (n < (uint)minCount || n > (uint)maxCount) continue;

            int arr = p + 4;
            long fin = arr + (long)n * 12;
            if (fin + 8 >= end) continue;
            if (!IsHandle(b, arr)) continue;
            if (!IsHandle(b, (int)fin - 12)) continue;

            int bad = 0, live = 0, qtyOk = 0, idxOk = 0;
            int badLimit = Math.Max(2, (int)n / 20);
            for (int q = arr; q < fin; q += 12)
            {
                if (BitConverter.ToUInt32(b, q) == 0 &&
                    BitConverter.ToUInt32(b, q + 4) == 0 &&
                    BitConverter.ToUInt32(b, q + 8) == 0) continue;      // hole
                if (!IsHandle(b, q)) { if (++bad > badLimit) break; continue; }
                live++;
                uint qty = BitConverter.ToUInt32(b, q + 4);
                uint idx = BitConverter.ToUInt32(b, q + 8);
                if (qty >= 1 && qty <= 9999) qtyOk++;
                if (idx < 1000000) idxOk++;
            }
            if (bad > badLimit) continue;
            if (live < minCount) continue;
            if (qtyOk < live * 0.9) continue;
            if (idxOk < live * 0.9) continue;
            // DENSITY. Without this, byte-aligned scanning throws up candidates whose
            // declared count is far larger than what is actually populated, for example
            // count=2865 against live=252. They survive every
            // check above because unpopulated records are skipped as holes, and being
            // the largest they would then WIN the collapse below and mask the real
            // array. A genuine array is nearly fully populated.
            if (live < n * 0.5) continue;

            var c = new Cand();
            c.CountOffset = p; c.ArrayStart = arr; c.Count = (int)n; c.ArrayEnd = fin; c.Live = live;
            outp.Add(c);
        }
        return outp;
    }
}
'@
}

function Find-ErInventories {
    <#  Locates EVERY held-item array in a character slot WITHOUT relying on known item
        ids. Scans for plausible count fields, then requires that the implied array be
        well formed and densely populated.

        Returns a list of @{ CountOffset; ArrayStart; Count; ArrayEnd; Live }, largest first.

        A slot holds more than one such array (held inventory, key items and storage
        box), so returning a single "best" match omits items.

        The scan is byte-aligned. Slot payloads are packed variable-length structures, so
        an inventory array can begin at any byte offset, and the start offset differs per
        slot. A scan stepping by more than one byte finds only the arrays whose offset is
        a multiple of the step, and reports the other slots as holding nothing. A test
        against one slot does not cover this: that slot's offset can match the step by
        chance.

        Tolerates "holes" (all-zero records mid-array).  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        [int]$MinCount = 20,
        [int]$MaxCount = 3000
    )

    $dataStart = $Entry.DataOffset + 16
    $dataEnd   = $Entry.DataOffset + $Entry.Size

    $cands = @([ErSaveScan]::Find($Bytes, $dataStart, $dataEnd, $MinCount, $MaxCount) |
        ForEach-Object {
            [pscustomobject]@{
                CountOffset = $_.CountOffset
                ArrayStart  = $_.ArrayStart
                Count       = $_.Count
                ArrayEnd    = $_.ArrayEnd
                Live        = $_.Live
            }
        })

    # collapse overlapping candidates, keeping the largest of each cluster
    $kept = New-Object Collections.ArrayList
    foreach ($c in ($cands | Sort-Object Count -Descending)) {
        $clash = $false
        foreach ($k in $kept) {
            if ($c.ArrayStart -lt $k.ArrayEnd -and $k.ArrayStart -lt $c.ArrayEnd) { $clash = $true; break }
        }
        if (-not $clash) { [void]$kept.Add($c) }
    }
    $kept | Sort-Object Count -Descending
}

function Find-ErInventory {
    <#  Back-compat shim returning only the largest array. Prefer Find-ErInventories;
        this one cannot see a slot's other arrays.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        [int]$MinCount = 20,
        [int]$MaxCount = 3000
    )
    $all = @(Find-ErInventories -Bytes $Bytes -Entry $Entry -MinCount $MinCount -MaxCount $MaxCount)
    if ($all.Count) { $all[0] } else { $null }
}

function Get-ErInventoryItems {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$Inventory)
    for ($p = $Inventory.ArrayStart; $p -lt $Inventory.ArrayEnd; $p += 12) {
        $h = [BitConverter]::ToUInt32($Bytes, $p)
        if ($h -eq 0) { continue }   # hole
        [pscustomobject]@{
            Offset   = $p
            Handle   = $h
            Category = '0x{0:X}' -f ($h -shr 28)
            ItemId   = [int]($h -band 0x0FFFFFFF)
            IsGoods  = (($h -shr 28) -eq 11)
            Quantity = [BitConverter]::ToUInt32($Bytes, $p + 4)
            InvIndex = [BitConverter]::ToUInt32($Bytes, $p + 8)
        }
    }
}

function Get-ErGoodsNameTable {
    <#  Shim for the pre-profile call sites. Goods names are per-build now, so this
        cannot be answered without knowing which build; it just forwards.  #>
    param($Profile)
    Get-ErNameTable -Family Goods -Profile $Profile
}

# --- Characters ---------------------------------------------------------------
# USER_DATA010 (the profile / menu summary entry) carries the character name for each
# of the 10 slots, UTF-16LE, at a fixed stride. Names are present even for slots that
# hold no character, so occupancy is decided from the slot payload itself, not the name.

function Get-ErCharacters {
    <#  Returns one row per save slot: Index, Name, Level, IsOccupied, Entry.
        Sampling the slot payload for non-zero bytes distinguishes a real character from
        a stale leftover name: an unused slot is entirely zero-filled.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $entries = @(Get-ErEntries -Bytes $Bytes)
    $profile = $entries | Where-Object { $_.Index -eq 10 }
    if (-not $profile) {
        throw 'This file has no profile summary entry (USER_DATA010), so character names cannot be read. It does not look like an Elden Ring save.'
    }
    $nameBase = $profile.DataOffset + 16 + 0x195E   # first slot's name
    $stride   = 0x24C

    foreach ($e in $entries) {
        if ($e.Index -gt 9) { continue }

        $p = $nameBase + $e.Index * $stride
        $sb = New-Object Text.StringBuilder
        for ($q = $p; $q -lt $p + 32; $q += 2) {
            $c = [BitConverter]::ToUInt16($Bytes, $q)
            if ($c -eq 0) { break }
            [void]$sb.Append([char]$c)
        }

        $ds = $e.DataOffset + 16; $de = $e.DataOffset + $e.Size
        $nz = 0
        for ($q = $ds; $q -lt $de; $q += 64) { if ($Bytes[$q] -ne 0) { $nz++ } }

        # Level comes from the same summary block, 0x22 past the name and NOT 4-byte
        # aligned. It is the cross-check that anchors the player block inside the slot
        # payload (Get-ErPlayerData), so it is read here rather than rediscovered there.
        $lvl = [BitConverter]::ToUInt32($Bytes, $p + 0x22)
        if ($nz -eq 0 -or $lvl -gt 9999) { $lvl = 0 }

        [pscustomobject]@{
            Index      = $e.Index
            Name       = $sb.ToString()
            Level      = [int]$lvl
            IsOccupied = ($nz -gt 0)
            Entry      = $e
        }
    }
}

function Resolve-ErSlot {
    <#  Maps a character name to its slot index. Matching is case-insensitive and accepts
        a unique prefix, so -Character fri finds "Frieren". Throws on no match or an
        ambiguous one, listing the candidates either way.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Character
    )
    $chars = @(Get-ErCharacters -Bytes $Bytes | Where-Object { $_.IsOccupied })
    $hit = @($chars | Where-Object { $_.Name -eq $Character })
    if (-not $hit.Count) { $hit = @($chars | Where-Object { $_.Name -like "$Character*" }) }
    if (-not $hit.Count) {
        throw "No character matches '$Character'. Available: $(($chars | ForEach-Object { '{0} (slot {1})' -f $_.Name, $_.Index }) -join ', ')"
    }
    if ($hit.Count -gt 1) {
        throw "'$Character' is ambiguous: $(($hit | ForEach-Object { $_.Name }) -join ', ')"
    }
    $hit[0].Index
}

# --- Player data: level and runes ----------------------------------------------
# A slot opens with its GaItem table, whose length varies per character, and the player
# block sits after it. Nothing in the file points at that block, so it is LOCATED BY A
# SCAN and not by a constant: measured starts ran from 0xA296 to 0xB712 across the 20
# characters in the three saves this was built against, so any one constant would be
# wrong for nearly all of them.
#
# Offsets below are relative to the LEVEL field, which is what the scan returns:
#     -0x58 hp        -0x54 max hp      -0x50 base max hp
#     -0x2C .. -0x10  vigor, mind, endurance, strength, dexterity, intelligence,
#                     faith, arcane (eight u32s, in that order)
#     +0x00 level     +0x04 runes held  +0x08 rune memory (lifetime total earned)
#     +0x34 character name, UTF-16LE, null terminated
# See SAVE-FORMAT.md section 13.

# The rune counter is a u32, but the game's own ceiling is 999,999,999: that is the cap
# on a rune item and on what the HUD renders. Nothing here writes above it.
$script:ErMaxRunes = 999999999

if (-not ('ErPlayerScan' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;

public static class ErPlayerScan
{
    // Candidate offsets of the LEVEL field. Byte-aligned, because the player block
    // follows a variable-length table and is not reliably 4-aligned.
    public static List<int> Find(byte[] b, int start, int end, int level, byte[] name)
    {
        var hits = new List<int>();
        for (int p = start + 0x58; p + 0x100 < end; p++)
        {
            uint lv = BitConverter.ToUInt32(b, p);
            if (lv < 1 || lv > 9999) continue;
            if (level > 0 && lv != (uint)level) continue;

            if (name != null && name.Length > 0)
            {
                bool ok = true;
                for (int k = 0; k < name.Length; k++)
                    if (b[p + 0x34 + k] != name[k]) { ok = false; break; }
                if (!ok) continue;
                // The stored name is null terminated. Without this, "Rhea" would also
                // match a character called "Rheagar".
                if (b[p + 0x34 + name.Length] != 0 || b[p + 0x35 + name.Length] != 0) continue;
            }

            bool bad = false;
            for (int s = 0; s < 8; s++)
            {
                uint v = BitConverter.ToUInt32(b, p - 0x2C + s * 4);
                if (v < 1 || v > 999) { bad = true; break; }   // 99 in vanilla; mods raise it
            }
            if (bad) continue;

            uint hp = BitConverter.ToUInt32(b, p - 0x58);
            uint maxHp = BitConverter.ToUInt32(b, p - 0x54);
            if (maxHp == 0 || maxHp > 99999 || hp > maxHp) continue;

            uint runes = BitConverter.ToUInt32(b, p + 4);
            uint memory = BitConverter.ToUInt32(b, p + 8);
            // Rune memory is the lifetime total, so it can never be below what is held.
            if (runes > 999999999 || memory > 999999999 || memory < runes) continue;

            hits.Add(p);
        }
        return hits;
    }
}
'@
}

function Get-ErPlayerData {
    <#  A character's level, held runes and rune memory, with the offsets to write to.

        The block is found by matching THREE things at once: the level the profile
        summary reports for that slot, the character's name at +0x34, and a plausible
        stat/HP/rune block around them. Any one of those alone is not enough to bet a
        write on, and a write here goes into a structure with no length field and no
        checksum of its own, so a near-miss corrupts the character rather than failing.

        Returns $null when no block matches, which is a real possibility on a save this
        was never tested against; callers report it rather than guessing an offset.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Char
    )
    $ds = $Char.Entry.DataOffset + 16
    $de = $Char.Entry.DataOffset + $Char.Entry.Size
    $nameBytes = if ($Char.Name) { [Text.Encoding]::Unicode.GetBytes($Char.Name) } else { $null }

    $hits = @([ErPlayerScan]::Find($Bytes, $ds, $de, [int]$Char.Level, $nameBytes))
    if (-not $hits.Count) { return $null }
    if ($hits.Count -gt 1) {
        # Never seen in testing. Reported rather than silently resolved, because the
        # tie-break would be a guess about which copy the game reads.
        Write-Warning ("Slot {0} '{1}': {2} candidate player blocks; using the first (0x{3:x})." -f `
            $Char.Index, $Char.Name, $hits.Count, $hits[0])
    }
    $p = $hits[0]

    [pscustomobject]@{
        Slot         = $Char.Index
        Name         = $Char.Name
        Offset       = $p                      # the level field: everything else is relative
        RunesOffset  = $p + 4
        MemoryOffset = $p + 8
        Level        = [int][BitConverter]::ToUInt32($Bytes, $p)
        Runes        = [int64][BitConverter]::ToUInt32($Bytes, $p + 4)
        RuneMemory   = [int64][BitConverter]::ToUInt32($Bytes, $p + 8)
        Hp           = [int][BitConverter]::ToUInt32($Bytes, $p - 0x58)
        MaxHp        = [int][BitConverter]::ToUInt32($Bytes, $p - 0x54)
        Stats        = [ordered]@{
            Vigor        = [int][BitConverter]::ToUInt32($Bytes, $p - 0x2C)
            Mind         = [int][BitConverter]::ToUInt32($Bytes, $p - 0x28)
            Endurance    = [int][BitConverter]::ToUInt32($Bytes, $p - 0x24)
            Strength     = [int][BitConverter]::ToUInt32($Bytes, $p - 0x20)
            Dexterity    = [int][BitConverter]::ToUInt32($Bytes, $p - 0x1C)
            Intelligence = [int][BitConverter]::ToUInt32($Bytes, $p - 0x18)
            Faith        = [int][BitConverter]::ToUInt32($Bytes, $p - 0x14)
            Arcane       = [int][BitConverter]::ToUInt32($Bytes, $p - 0x10)
        }
    }
}

function Get-ErMaxRunes {
    <#  The highest rune count the editors will write. #>
    $script:ErMaxRunes
}

# --- Name tables --------------------------------------------------------------
# Export-ErNames.ps1 writes one TSV per family into data/<profile>/, and ErProfileLib's
# Get-ErProfile loads a whole profile's worth at once. These helpers only reach into an
# already-loaded profile; nothing here reads the filesystem.

function Get-ErNameTable {
    <#  One family's id -> name map, out of a loaded profile.

        Names are per-build, and there is no build-neutral table to fall back on: a mod
        leaves stale vanilla names on ids it never defined, so reading the wrong build's
        table does not fail, it reports the wrong item. Hence the throw rather than an
        empty table.

        Families: Goods, Weapon, Protector, Accessory, Gem.  #>
    param(
        [ValidateSet('Goods', 'Weapon', 'Protector', 'Accessory', 'Gem')]
        [string]$Family = 'Goods',
        $Profile
    )
    if (-not $Profile) {
        throw "Get-ErNameTable needs -Profile <profile object>. Load one with Get-ErProfile from ErProfileLib.ps1 - there is no build-neutral name table."
    }
    if (-not $Profile.Names.ContainsKey($Family)) {
        throw "Profile '$($Profile.Name)' carries no $Family names. Regenerate it with Export-ErNames.ps1 -Profile $($Profile.Name)."
    }
    $Profile.Names[$Family]
}

# --- GaItem table -------------------------------------------------------------
# Goods carry their id in the handle. Everything else (weapons, armour, talismans,
# ashes of war) carries only a DYNAMIC handle in the inventory record; the real param
# id lives in a separate GaItem table earlier in the slot.
#
# Layout, established empirically (see SAVE-FORMAT.md section 6):
#   entry = { u32 ga_item_handle; u32 param_id; ...trailing fields... }
# The trailing part is category-dependent: weapon entries measured 21 bytes apart,
# armour entries 16. The table is NOT a fixed-stride array and its entries are not
# all 4-byte aligned. Rather than model every shape, index it by locating each handle:
# handle and param_id are always the first two u32s of an entry, which is all a level
# edit needs.

function Get-ErGaItemIndex {
    <#  Maps ga_item_handle -> byte offset of its GaItem entry.

        Scans the slot from the start of its payload up to the first held-item array,
        BYTE-aligned rather than 4-byte aligned, because entry strides are not multiples
        of 4. The first occurrence of a handle wins: handles reappear later in equip-slot
        lists (plain u32 arrays of handles, carrying no param id), and those must not be
        mistaken for table entries.

        THE UPPER BOUND IS ONLY AS GOOD AS Find-ErInventories. While that function missed
        slot 3's real array and returned the storage box instead, this window stretched
        ~40KB too far and ran straight across the real inventory records. Callers write to
        GaOffset + 4 (Edit-ErUpgrade), so a handle mapped into record bytes would be a
        write to a garbage offset, not merely a bad report. Two defences, both cheap:

          * inventory ranges are skipped explicitly, so a partial or wrong discovery can
            never map a handle to a byte inside a record array;
          * a candidate must carry a plausible param id at +4. Real GaItem rows do; the
            middle of an unrelated structure usually does not.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        $Inventories
    )
    $from = $Entry.DataOffset + 16
    if (-not $Inventories) { $Inventories = @(Find-ErInventories -Bytes $Bytes -Entry $Entry) }
    $first = @($Inventories | Sort-Object ArrayStart | Select-Object -First 1)
    $to = if ($first.Count) { [int]$first[0].ArrayStart } else { $Entry.DataOffset + $Entry.Size }

    $ranges = @($Inventories | Sort-Object ArrayStart)

    $index = @{}
    $at = $from
    while ($at -lt $to - 8) {
        $skipped = $false
        foreach ($r in $ranges) {
            if ($at -ge $r.ArrayStart -and $at -lt $r.ArrayEnd) { $at = [int]$r.ArrayEnd; $skipped = $true; break }
        }
        if ($skipped) { continue }

        $h = [BitConverter]::ToUInt32($Bytes, $at)
        if (($h -shr 28) -ge 8) {
            # Armour rows carry a category nibble in this field (0x10049bb0 -> 302000), so the
            # plausibility test must run on the MASKED value. Comparing the raw u32 against
            # an id ceiling rejected every armour entry in the slot.
            $paramId = [BitConverter]::ToUInt32($Bytes, $at + 4) -band 0x0FFFFFFF
            if ($paramId -ne 0 -and $paramId -lt 200000000 -and -not $index.ContainsKey($h)) {
                $index[$h] = $at
            }
        }
        $at++
    }
    $index
}

# Whether a weapon reinforces at all, and how far, is a property of the BUILD and not of
# the id. It comes from EquipParamWeapon's reinforceTypeId, exported per profile into
# data/<profile>/weaponlevels.tsv; a ceiling of 0 means there is no reinforcement path,
# and writing a level onto one of those produces a param id with no matching row.
#
# An id range cannot answer this. Vanilla's Meteorite Staff (33250000) is +0 in the base
# game and +15 under Convergence, so the same id has two different ceilings. Only the
# 50-59 million decade is ammunition: the 60- and 90-million weapons carry real ceilings
# (201 in vanilla, 258 in Convergence). The regulation covers both cases, so no id range
# is hardcoded here.

function Get-ErEquipment {
    <#  Resolves every non-goods inventory record to its real param id, and for weapons
        to a base id plus a reinforcement level.

        Weapon param id = base + level, where level is the last TWO digits and the base
        carries the affinity in the hundreds digits: 11050300 is a Quality Morning Star
        at +0, not a Morning Star at +300. Splitting at % 10000 instead reads the affinity
        as part of the level, and an upgrade written from that base strips the infusion
        without reporting an error.
        The exported tables are keyed the same way (weaponnames.tsv carries a row per
        affinity, "Quality Morning Star" among them), so base lookups need no adjustment.
        Armour param id = ga_item_id AND 0x0FFFFFFF (verified 34 of 34). Armour has no
        reinforcement in Elden Ring.

        Each weapon also carries MaxLevel, the build's ceiling for that specific weapon.
        Upgradeable is derived from it, so a caller never has to know an id rule.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        $Inventories,
        $GaIndex,
        $WeaponNames,
        $ProtectorNames,
        $MaxLevels,
        $Profile
    )
    if (-not $Inventories)    { $Inventories    = @(Find-ErInventories -Bytes $Bytes -Entry $Entry) }
    if (-not $GaIndex)        { $GaIndex        = Get-ErGaItemIndex -Bytes $Bytes -Entry $Entry -Inventories $Inventories }
    if (-not $WeaponNames)    { $WeaponNames    = Get-ErNameTable -Family Weapon -Profile $Profile }
    if (-not $ProtectorNames) { $ProtectorNames = Get-ErNameTable -Family Protector -Profile $Profile }
    if (-not $MaxLevels) {
        if (-not $Profile) {
            throw "Get-ErEquipment needs -Profile (or -MaxLevels): the reinforcement ceiling is per build, and a guess writes unreachable param ids."
        }
        $MaxLevels = $Profile.MaxLevel
    }

    foreach ($inv in $Inventories) {
        foreach ($it in (Get-ErInventoryItems -Bytes $Bytes -Inventory $inv)) {
            if ($it.IsGoods) { continue }
            if (-not $GaIndex.ContainsKey($it.Handle)) { continue }
            $ga = $GaIndex[$it.Handle]
            $paramId = [BitConverter]::ToUInt32($Bytes, $ga + 4)

            $kind = 'Other'; $base = $null; $level = $null; $name = $null; $canUp = $false
            $max  = $null
            if ($it.Category -eq '0x8') {
                $kind  = 'Weapon'
                $level = [int]($paramId % 100)
                $base  = [int]($paramId - $level)
                if ($WeaponNames.ContainsKey($base)) { $name = $WeaponNames[$base] }
                # No row in weaponlevels.tsv means this build does not define the weapon,
                # which is a stronger "no" than a ceiling of 0. Leave MaxLevel null so a
                # caller can tell the two apart, and refuse the upgrade either way.
                if ($MaxLevels.ContainsKey($base)) { $max = [int]$MaxLevels[$base] }
                $canUp = ($null -ne $max) -and ($max -gt 0) -and
                         [bool]$name -and ($name -ne '[ERROR]') -and ($name -ne 'DLC dummy')
            }
            elseif ($it.Category -eq '0x9') {
                $kind = 'Armour'
                $base = [int]($paramId -band 0x0FFFFFFF)
                if ($ProtectorNames.ContainsKey($base)) { $name = $ProtectorNames[$base] }
            }

            [pscustomobject]@{
                Kind         = $kind
                Category     = $it.Category
                Handle       = $it.Handle
                RecordOffset = $it.Offset
                GaOffset     = $ga
                ParamId      = $paramId
                BaseId       = $base
                Level        = $level
                MaxLevel     = $max
                Name         = $name
                Upgradeable  = $canUp
                Quantity     = $it.Quantity
            }
        }
    }
}

# --- Spirit ashes -------------------------------------------------------------
# A spirit ash is a GOOD, so its level is encoded in the id carried by the inventory
# handle itself, so no GaItem lookup is needed. The name table carries one entry per
# level ("Lone Wolf Ashes", "Lone Wolf Ashes +1" ... "+10"), so a family's levels and its
# maximum are read straight out of the names rather than assumed from id arithmetic.
# That distinction matters: flasks and pots also use "+N" names but step ids by 2 per
# level, so an arithmetic rule would mis-target them.

function Get-ErAshLadders {
    <#  Returns familyName -> @{ Max = <int>; ByLevel = @{ level -> id } } for every
        goods family whose names look like spirit ashes.  #>
    param($GoodsNames, $Profile)
    if (-not $GoodsNames) { $GoodsNames = Get-ErNameTable -Family Goods -Profile $Profile }

    $ladders = @{}
    foreach ($id in $GoodsNames.Keys) {
        $nm = $GoodsNames[$id]
        if ($nm -notmatch 'Ashes(\s\+\d+)?\s*$') { continue }
        $level = 0
        $fam = $nm
        if ($nm -match '^(.*?)\s\+(\d+)\s*$') { $fam = $Matches[1]; $level = [int]$Matches[2] }
        $fam = $fam.Trim()
        if (-not $ladders.ContainsKey($fam)) { $ladders[$fam] = @{ Max = 0; ByLevel = @{} } }
        $ladders[$fam].ByLevel[$level] = [int]$id
        if ($level -gt $ladders[$fam].Max) { $ladders[$fam].Max = $level }
    }
    $ladders
}

function Get-ErSpiritAshes {
    <#  Every held spirit ash, with its current level and the top of its ladder.  #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)]$Entry,
        $Inventories,
        $GoodsNames,
        $Ladders,
        $Profile
    )
    if (-not $Inventories) { $Inventories = @(Find-ErInventories -Bytes $Bytes -Entry $Entry) }
    if (-not $GoodsNames)  { $GoodsNames  = Get-ErNameTable -Family Goods -Profile $Profile }
    if (-not $Ladders)     { $Ladders     = Get-ErAshLadders -GoodsNames $GoodsNames }

    foreach ($inv in $Inventories) {
        foreach ($it in (Get-ErInventoryItems -Bytes $Bytes -Inventory $inv)) {
            if (-not $it.IsGoods) { continue }
            if (-not $GoodsNames.ContainsKey($it.ItemId)) { continue }
            $nm = $GoodsNames[$it.ItemId]
            if ($nm -notmatch 'Ashes(\s\+\d+)?\s*$') { continue }
            $level = 0; $fam = $nm
            if ($nm -match '^(.*?)\s\+(\d+)\s*$') { $fam = $Matches[1]; $level = [int]$Matches[2] }
            $fam = $fam.Trim()
            if (-not $Ladders.ContainsKey($fam)) { continue }
            $ladder = $Ladders[$fam]
            $topId = $null
            if ($ladder.ByLevel.ContainsKey($ladder.Max)) { $topId = $ladder.ByLevel[$ladder.Max] }
            [pscustomobject]@{
                Offset   = $it.Offset
                ItemId   = $it.ItemId
                Family   = $fam
                Name     = $nm
                Level    = $level
                MaxLevel = $ladder.Max
                MaxId    = $topId
                Quantity = $it.Quantity
            }
        }
    }
}

