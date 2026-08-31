# Elden Ring Save File Structure

This document gives the technical structure of the Elden Ring save file. It also gives
the structure of the game data files that hold the item names and the item tables.

The text uses Simplified Technical English. The sentences are short. The verbs are
active. Each sentence gives one item of information.

The structures were verified against Elden Ring, and against Elden Ring with The
Convergence 3.0.1.2, in August 2026. The tools in this repository read and write these
structures. See [README.md](README.md) for the installation instructions and the usage
instructions.

---

## 1. Terminology

| Term | Meaning |
|---|---|
| Save file | The file that the game writes. It contains all the characters. |
| Container | The BND4 archive structure of the save file. |
| Entry | One element of the container. The save file has 12 entries. |
| Slot | One entry that holds one character. |
| Payload | The data bytes of one entry. |
| Record | One 12-byte element of an item array. |
| Handle | The 32-bit identifier of one item in a record. |
| Param id | The identifier of one row in a game data table. |
| Profile | The set of data tables of one build. |
| Build | The base game, or the base game with the mod. |

---

## 2. File locations

The game writes the save files to this directory:

```
%APPDATA%\EldenRing\<steamId64>\
```

The base game writes the file `ER0000.sl2`. The Convergence mod writes the file
`ER0000.cnv`. The file `mod\altsaves.toml` in the mod directory sets this extension.

If both files are present, they are different playthroughs. They hold different
characters. Do not assume that one file is a copy of the other file.

Steam Cloud synchronizes this directory. If the game and the file on the disk do not
agree, examine Steam Cloud first.

---

## 3. Container structure

The save file is a BND4 archive of 28,967,888 bytes. The archive has 12 entries.

The size and the entry count are constants of the format. The container is preallocated.
All ten character slots are present in each file, and an empty slot is zero-filled.
Therefore, the number of characters and the progression of the characters do not change
the size of the file.

```
0x00  "BND4"                     magic
0x0C  u32  entryCount            = 12
0x40  entry headers, 32 bytes each:
        +0x00  u64  flags
        +0x08  u64  size
        +0x10  u32  dataOffset
        +0x14  u32  nameOffset   -> UTF-16LE name, null-terminated
```

The entry names are `USER_DATA000` to `USER_DATA011`.

| Entry | Content | Size |
|---|---|---|
| `USER_DATA000` to `USER_DATA009` | The ten character slots | `0x280010` bytes each |
| `USER_DATA010` | The profile summary and the menu summary | `0x60010` bytes |
| `USER_DATA011` | Game settings | `0x240020` bytes |

The entry sizes give a total of 28,967,120 bytes. The remaining 768 bytes are the archive
header, the 12 entry headers and the name table.

The save file is not encrypted.

### 3.1 Entry checksum

Each entry payload starts with a checksum:

```
payload = [16-byte MD5 of the remaining bytes][data]
```

After a change to the data, calculate the MD5 again over `data[16:]`. Write the new MD5
to the first 16 bytes of the payload. If the MD5 is not correct, the game refuses the
slot.

The container has no checksum of its own. Therefore, only the changed entry needs a new
MD5.

---

## 4. Character slots

### 4.1 Character names

The entry `USER_DATA010` holds the name of each of the ten slots. The names are UTF-16LE
strings. Calculate the address of one name with this equation:

```
name[i] = USER_DATA010.dataOffset + 16 + 0x195E + i * 0x24C
```

The value 16 in the equation is the length of the MD5 checksum.

A name is present for each slot. An empty slot also has a name (because all 10
slots are pre-allocated).

Always identify a character by the name. A slot number gives no information about the
character in the slot.

### 4.2 Occupancy

To find if a slot holds a character, examine the bytes of the slot payload. An empty slot
contains only zero bytes. A used slot contains approximately 13% to 18% non-zero bytes.

### 4.3 Slot layout

The slot payload is a sequence of structures of variable length. The structures include:

* the GaItem table, at payload offset `+0x20` (see section 6);
* the player block, which holds the stats, the level and the runes (see section 13);
* one or more item arrays (see section 5);
* equipment lists, which are plain arrays of handles;
* acquisition tables, which are sorted arrays of `(goodsId, flag)` pairs.

The offsets of these structures are not constant. The offsets move when the game writes
the save file again. Play changes the length of the structures that are before them.

Do not keep a byte offset from a previous read. Always find each structure again.

---

## 5. Item arrays

### 5.1 Structure

An item array is a continuous sequence of 12-byte records. A `u32` count field is
immediately before the first record. Zero bytes usually follow the last record.

```
[u32 count][record][record] ... [record][zero fill]

record = {
    u32 ga_item_handle;
    u32 quantity;
    u32 inventory_index;
}
```

This schematic shows the byte order of an array with N records:

```
+0x00  NN 00 00 00                              count = N
+0x04  <handle>     | <quantity>  | <index>     the first record
...
       <handle>     | <quantity>  | <index>     the record N
       00 00 00 00                              zero fill
```

Each field is a little-endian `u32`.

### 5.2 The field order

A sequence of 12-byte records can be read at three different phases. More than one
interpretation is self-consistent. The count field gives the correct interpretation. The
count field is exactly 4 bytes before the first record only with the field order
`{handle, quantity, inventory_index}`.

### 5.3 Item handles

The four most significant bits of the handle give the category. The 28 least significant
bits give the parameter that follows.

| Top nibble | Category | Content of the low 28 bits |
|---|---|---|
| `0xB` | Goods and consumables | The goods param id |
| `0x8` | Weapons | A dynamic handle. See section 6. |
| `0x9` | Armour | A dynamic handle. See section 6. |
| `0xA` | Accessories and talismans | A dynamic handle |

A goods handle contains the item id. Therefore, a goods record needs no other table. A
goods record is the most simple record to read and to change.

A weapon record and an armour record contain no item id. Each record contains only a
dynamic handle. Section 6 tells how to find the item id.

### 5.4 The inventory_index field

The game gives a new `inventory_index` to each record at each save operation. The values
increase with the sequence of acquisition.

Do not use the `inventory_index` as an identifier. Do not write a constant value to it.

### 5.5 Start offsets

**The structures in a slot payload have variable length. An item array also has variable
length. Therefore, an item array can start at any byte offset.**

The start offset has no alignment to any constant. The start offset is different in each
slot, because the structures before the array are different in each slot.

To find the arrays, examine every byte offset. A scan that moves in steps of more than
one byte finds only the arrays whose start offset is a multiple of the step. Such a scan
gives no error message for the other arrays. It reports them as absent. It can also find
a smaller array in the same slot and report that array as the held inventory.

A test with one slot is not sufficient. The start offset of one slot can agree with the
step by chance.

### 5.6 Rules for a valid array

A scan of every byte offset finds candidate arrays that are not correct. Use these rules
to accept or to reject a candidate array:

1. **Test the density.** The number of populated records must be more than 50% of the
   declared count. A correct array is almost fully populated. An incorrect candidate
   usually declares a large count and has few populated records. Such a candidate obeys
   all the other rules, because the reader ignores the empty records as holes.
2. **Test the values statistically.** More than 90% of the records must have a quantity
   from 1 to 9999 and a possible `inventory_index`. Random data does not obey this rule.
3. **Do not require zero fill after the last record.** Zero fill is usual but not
   reliable. Another live record can follow an array immediately.
4. **Accept holes.** A record that contains only zero bytes can occur in the middle of an
   array. Do not stop the scan at the first invalid record.

### 5.7 More than one array in a slot

One slot contains more than one item array. The usual arrays are:

* the held inventory, which is the largest array;
* the key items;
* the storage box.

Read all the arrays. If you read only the largest array, you do not see all the items.

The storage box can show the same items as the held inventory. Compare the two arrays to
find if a change reached the character.

### 5.8 Do not scan the full slot for handles

Data that is not an item array can contain bytes with the pattern `0xB000xxxx`. A reader
that accepts such bytes as a record gives a known item name with an impossible quantity
and an impossible `inventory_index`.

Read item records only in an array that obeys the rules in section 5.6.

For diagnosis, a scan of the full file for one handle value is permitted. Use this scan
only to find if an id occurs in the file. Examine the adjacent bytes before you accept
the result.

---

## 6. The GaItem table

### 6.1 Function

A goods record contains its item id in the handle. A weapon record, an armour record and
a talisman record do not. These records contain a dynamic handle. The GaItem table gives
the item id for a dynamic handle.

```
entry = {
    u32 ga_item_handle;
    u32 param_id;
    ...more fields, which are different for each category...
}
```

The table starts at slot payload offset `+0x20`.

### 6.2 Scan rules

The GaItem entries have variable length, because the trailing fields are different for
each category. Therefore, the table has no constant stride, and an entry can start at any
byte offset. The measured space between two weapon entries is 21 bytes. The measured
space between two armour entries is 16 bytes.

To find the entries, examine every byte offset. A scan that moves in steps of more than
one byte finds only some of the entries.

Use the first occurrence of a handle. Search only between the start of the slot and the
first item array. The handles occur again after the item arrays, in the equipment lists.
The equipment lists contain no param id.

### 6.3 Decode of the param id

| Category | Item type | Rule |
|---|---|---|
| `0x8` | Weapon | `level = param_id % 100`, `base = param_id - level` |
| `0x9` | Armour | `protector_id = param_id AND 0x0FFFFFFF` |
| `0xA` | Talisman | Not in this table. The location is not known. |

Example: `33130006` is the Astrologer's Staff (`33130000`) at level +6. The value
`0x10099cf0` is protector id `630000`, the Astrologer Hood.

**The param field is not a bare id.** An armour row keeps a category value in the most
significant bits. The value `0x10049bb0` is 268,737,456 as a `u32`. The value becomes
protector id `302000` after the mask operation. Apply all range tests to the value after
the mask operation. A range test on the unmasked value refuses all armour entries.

Elden Ring has no reinforcement for armour. A change of the item level applies only to
weapons.

### 6.4 Weapon id, affinity and level

A weapon param id has three components:

```
param_id = base + affinity * 100 + level
```

The affinity is a part of the base value. The level is only the last two digits.

Example: `11050300` is a Quality Morning Star at level +0. The value is not a Morning
Star at level +300.

If you divide the id at `% 10000`, you read the affinity as a part of the level. An
upgrade that you calculate from that base gives `11050015`. That id is a Standard Morning
Star at +15. The infusion is lost.

The exported name tables contain one row for each affinity. The base game has 13
affinities for each weapon that accepts an infusion. The Convergence mod has 22.

### 6.5 The reinforcement ceiling

Elden Ring does not store a row for each level of a weapon. A weapon has one row. The
levels are stored indirectly:

```
EquipParamWeapon[base].reinforceTypeId = T
the levels are the ReinforceParamWeapon rows T+0 to T+N
the maximum level = N
```

A ceiling of 0 means that the weapon has no reinforcement path. Do not write a level to
such a weapon. The result is a param id with no matching row.

The ceilings are different in each build:

| Profile | Distribution of the ceilings |
|---|---|
| Base game | +25 for 3327 weapons, +10 for 233 weapons, +0 for 76 weapons |
| Convergence | +15 for 4654 weapons, +25 for 7 weapons, +10 for 3, +0 for 81 |

An id range cannot give the ceiling. The base game gives the Meteorite Staff (33250000) a
ceiling of +0. The Convergence mod gives the same id a ceiling of +15. Only the ids from
50,000,000 to 59,999,999 are ammunition. The weapons with ids near 60,000,000 and
90,000,000 have real ceilings.

Item description text also cannot give the ceiling. The Convergence description text says
"Strengthens armaments to +10". The Convergence regulation file gives +15. Always read
the ceiling from the regulation file.

### 6.6 Spirit ashes

Spirit ashes are goods. The level is a component of the goods id. The handle contains the
id. Therefore, no GaItem entry is necessary.

The name table contains one entry for each level, for example "Lone Wolf Ashes +10". Find
the levels of a family and its maximum level by the name. Do not calculate the levels
from the id.

Arithmetic on the id is not safe. Flasks and pots also use "+N" names, but their ids
increase by 2 for each level. Of 68 ash families, 66 families have a maximum of +10.

---

## 7. Item names

### 7.1 Source of the names

The save file contains no item names. The names are in the message archives of the game
or of the mod.

The pipeline has four stages:

```
item*.msgbnd.dcx  --Oodle Kraken-->  BND4  --extract-->  *Name*.fmg  --parse-->  TSV
```

Rules for each stage:

* The DCX header fields are big-endian. The payload is Oodle Kraken. Decompression needs
  the function `OodleLZ_Decompress` from the game file `oo2core_6_win64.dll`. The function
  takes 14 arguments and uses the cdecl convention.
* The internal BND4 uses entry headers of 36 bytes (format `0x74`). The save file uses
  entry headers of 32 bytes. The two layouts are different.
* The archive contains more than one name FMG for each family. One archive holds 78
  entries. These include `GoodsName.fmg` with 2,387 names, `GoodsName_dlc01.fmg` with 841
  names, and `GoodsName_dlc02.fmg` with 1 name. Read all of them. Merge them in sequence.
  A later file replaces an earlier value.

### 7.2 FMG version 2 structure

```
0x0C  u32  groupCount
0x10  u32  stringCount
0x18  u64  offset of the offset table
0x28  the groups, 16 bytes each:
        { u32 offsetIndex; u32 firstId; u32 lastId; u32 pad }
      the strings, UTF-16LE, at absolute 64-bit offsets
```

To test the result, add the `offsetIndex` of the last group to the span of that group.
The sum must be equal to `stringCount`.

### 7.3 Vanilla archives

For the base game, the message archives are in the encrypted files `Data0.bhd`,
`Data0.bdt` and the equivalent DLC files. To read them, the tools use:

* one RSA public key for each archive, for the raw modular exponentiation of the `.bhd`;
* a 64-bit path hash with the rule `hash = char + 133 * hash`.

These constants are in the constants block at the start of `ErArchiveLib.ps1`. If a game
patch stops the archive reading, update that block.

---

## 8. Game data tables

### 8.1 regulation.bin

The file `regulation.bin` holds the param tables of a build. The structure is:

```
AES-256-CBC  ->  DCX  ->  BND4  ->  the param files
```

The AES initialization vector is the first 16 bytes of the file. The AES key is a
constant in `ErArchiveLib.ps1`. There is no padding.

The tools read the row ids of the param tables. Row ids need no paramdef file.

The current game patches compress `regulation.bin` with ZSTD. The export tools use
Node.js v23 or later for that operation. The save editor does not read this file.

### 8.2 The one decoded field

The tools decode one field only: `EquipParamWeapon.reinforceTypeId`. The offset of that
field was calculated from the Paramdex definition (DataVersion 6).

Two rules apply to such a calculation:

1. Bitfields pack by their width, not by their type name. The fields `u8 x:1` and
   `dummy8 y:7` share one byte.
2. The calculated row size must be equal to the row stride in the file. The calculated
   offset must have natural alignment.

The current values are a row size of 664 bytes and a field offset of 218 (`s16`). If a
patch changes the layout, the row-size test fails and names this block.

### 8.3 Names and ids are not the same set

A name says what an id is called. A param row says if the id exists.

The two sets are different. Some param rows have no name. A mod leaves the old names on
ids that the mod does not define.

Therefore, always test the existence of an id against the param table. Do not test the
existence against the name table.

---

## 9. Profiles

A profile is the set of tables of one build. The tools keep one directory for each
profile:

```
data/vanilla/
data/convergence/
```

Each directory holds five name tables, the file `paramids.tsv` and the file
`weaponlevels.tsv`.

The Convergence mod uses a subset of the vanilla goods ids. The mod gives new names to
that subset. The other ids keep their old vanilla names. Therefore, id 10102 still shows
"Smithing Stone [3]", but the mod does not use that id.

### 9.1 How to identify a renamed id

Two independent signals agree. Neither signal needs a save file.

1. **The name has no bracket.** The base game numbers these items, for example "Smithing
   Stone [3]". The Convergence mod uses a word for the tier, for example "Large", "Great",
   "Colossal", "Sprouting", "Budding" or "Elder". An item with a bracket is an id that the
   mod does not use.
2. **The caption gives a different maximum.** The file `GoodsCaption.fmg` confirms the
   first signal. An unused id keeps the vanilla maximum for its bracket. A renamed id has
   the maximum of the mod. Example: id 10107 is "Great Smithing Stone" and its caption
   says +9. The vanilla item with bracket [8] said +24.

### 9.2 Convergence smithing stones (version 3.0.1.2)

| Regular line | Id | Maximum | Somber line | Id | Maximum |
|---|---|---|---|---|---|
| Smithing Stone | 10101 | +3 | Somber Stone | 10160 | +3 |
| Large Smithing Stone | 10105 | +6 | Large Somber Stone | 10164 | +5 |
| Great Smithing Stone | 10107 | +9 | Great Somber Stone | 10165 | +7 |
| None | | | Colossal Somber Stone | 10167 | +9 |
| Ancient Smithing Stone | 10140 | +10 | Ancient Somber Stone | 10168 | +10 |

The regular line has no Colossal tier. Only the somber line and the shadow lines have a
Colossal tier.

The shadow (DLC) lines have new names for all five tiers. The ids 10110 to 10114 are the
Shadow, Large, Great, Colossal and Primordial Smithing Stone. The ids 10170 to 10174 are
the equivalent somber items.

The mod does not use these vanilla ids: 10100, 10102 to 10104, 10106, 10161 to 10163 and
10166. They keep their old names and their old captions.

### 9.3 Convergence gloveworts (version 3.0.1.2)

| Grave line (ordinary ashes) | Id | Ghost line (renowned ashes) | Id | Maximum |
|---|---|---|---|---|
| Sprouting Grave Glovewort | 10900 | Sprouting Ghost Glovewort | 10910 | +3 |
| Seedling Grave Glovewort | 10903 | Seedling Ghost Glovewort | 10913 | +5 |
| Budding Grave Glovewort | 10906 | Budding Ghost Glovewort | 10916 | +7 |
| Blooming Grave Glovewort | 10908 | Blooming Ghost Glovewort | 10918 | +9 |
| Elder Grave Glovewort | 10909 | Elder Ghost Glovewort | 10919 | +10 |

The mod does not use these ids: 10901, 10902, 10904, 10905, 10907, 10911, 10912, 10914,
10915 and 10917.

---

## 10. Unknown item ids

A save file can contain a correct item record with an id that no available build defines.
Such a record is not necessarily an error of the reader. A different version of a mod, or
a third-party save editor, can put such an id in a save file.

To classify an unknown id, do these tests:

| Test | Interpretation |
|---|---|
| Examine the position in the array. | A record in the middle of an array, with a correct quantity and an increasing `inventory_index`, is a real record. |
| Examine the handle category. | If the top nibble is `0xB`, the low 28 bits are the goods id. No GaItem entry is necessary. |
| Search the param tables of each build. | A row in `EquipParamGoods` gives the build that defines the item. |
| Search all params for the value. | If no param refers to the id, no build can give the item to a character. |
| Search the name tables of each build. | A name in an FMG gives the build that defines the item. |
| Examine the loose param directory of the mod. | A mod can add rows in loose param files. |

Do not attribute an id to an arithmetic rule. A small set of ids can appear to obey a
rule of that type by coincidence.

The tools divide the unknown ids into two classes, because the two classes need different
advice:

* **OtherBuild.** A different known profile defines the id. The content is real. To edit
  the item, do not use the `-BaseGame` option.
* **Orphan.** No known profile defines the id. The `-BaseGame` option is not the cause.
  The tools report the id and do not change it.

The tools have no list of permitted ids. The tools report every unknown id. A list of
exceptions would also suppress the report of the next real error.

---

## 11. Safety of edits

### 11.1 Safe: a change of quantity

The quantity is always at `handle_offset + 4`. This offset is correct in each possible
record phase. The operation writes 4 bytes, and it changes no count, no
`inventory_index` and no record structure.

This operation is confirmed. The game loaded the changed save file, played, and wrote the
save file again with the new values.

### 11.2 Safe: a change of level

A weapon level edit writes the param id in the GaItem table. A spirit ash edit writes the
handle in the item record. Each operation writes 4 bytes, and neither operation changes a
count or moves data.

After such an edit, only the written bytes and the entry MD5 are different from the
backup copy.

### 11.3 Not confirmed: a new item

The addition of a record is possible but not confirmed. These items are known: the record
layout, the count field, the zero fill after the array, and the rule that goods need no
GaItem entry.

These items are not known:

1. **The allocation of the `inventory_index`.** The game gives a new value at each save
   operation. If a field elsewhere in the slot holds the next value, a manual value can
   cause a collision later.
2. **The acquisition tables.** Each slot holds sorted arrays of `(goodsId, flag)` pairs.
   These arrays appear to record "the character had this item". An insertion into a sorted
   array needs a move of data and a new count. The result of no insertion is not known.
3. **The declared capacity of the array.** Zero fill follows the array, but the maximum is
   not confirmed. A report gives 2688 for the base game.

An alternative operation has a lower risk. Write a new handle over the handle of an
unnecessary record. This operation uses an `inventory_index` that the game gave. It
changes no count. It writes 8 bytes. The old item is lost.

### 11.4 Safe: a change of the rune count

The rune counter is one `u32` in the player block (section 13). The operation writes 4
bytes and moves nothing. The rune memory field beside it is a second `u32` of the same
kind.

The value has a ceiling of 999999999. That number is the ceiling the game itself uses for
a rune total. A larger value fits in the field but is not a value the game writes.

Hold the rule that the rune memory is not less than the held count. The rune memory is
the total of all runes that the character earned, so the game never writes a save file in
which the held count is the larger of the two.

The risk in this edit is not the write. It is the address. Nothing in the file points at
the player block, so the address comes from a scan, and a scan that matches the wrong
bytes writes into an unrelated structure. Section 13 gives the tests that the scan
applies.

### 11.5 Conditions for all edits

1. Close the game first. The game writes the save file again when it stops. That
   operation discards all changes on the disk.
2. Make a backup copy first.
3. Calculate the MD5 of the changed entry again.
4. Read the file again and test all 12 checksums.

---

## 12. Data that is not stable

The contents of a slot change with play. The number of records, the number of arrays and
the offset of each array are all different after a play session.

Therefore, do not use a count from a previous read as a test value. Find the structures
again at each run.

For a regression test, use a character that is not in use. The record counts of such a
character stay constant, and a change in the counts then shows an error in the reader.

---

## 13. The player block (level and runes)

Each slot holds one player block. It carries the vital values, the eight stats, the
level, the runes and the character name.

### 13.1 Position

The block follows the GaItem table. That table has a length that changes with the items
of the character, so the block has no constant address. Measured starts, from the start
of the slot payload:

| Save | Characters | Range of the start |
|---|---|---|
| Convergence `.cnv` | 5 | `0xA296` - `0xA9F4` |
| Vanilla `.sl2` | 10 | `0xA2A4` - `0xB712` |

Nothing in the file points at the block. Find it at each run.

### 13.2 Layout

All fields are `u32`. The offsets below are relative to the **level** field, because the
level is the field the scan matches:

| Offset | Field |
|---|---|
| `-0x58` | hp |
| `-0x54` | max hp |
| `-0x50` | base max hp |
| `-0x2C` | vigor |
| `-0x28` | mind |
| `-0x24` | endurance |
| `-0x20` | strength |
| `-0x1C` | dexterity |
| `-0x18` | intelligence |
| `-0x14` | faith |
| `-0x10` | arcane |
| `+0x00` | level |
| `+0x04` | runes held |
| `+0x08` | rune memory (the total of all runes earned) |
| `+0x34` | character name, UTF-16LE, null terminated |

The block is not 4-byte aligned. It follows a structure of variable length, so scan for
it byte by byte, as for the item arrays (section 5.5).

"Runes held" is the counter of the HUD. It is not a Rune item of the inventory: those are
goods, with a goods id and a quantity, and section 5 covers them.

### 13.3 Rules for a valid block

A single test gives false matches. Apply all of these together:

1. The level equals the level of the profile summary for that slot (section 13.4).
2. The character name of the slot is at `+0x34`, and a null `u16` follows it. Without the
   test for the terminator, "Rhea" also matches a character named "Rheagar".
3. The eight stats are each in the range 1 to 999. The base game has a maximum of 99. A
   mod raises it, so a limit of 99 here is too strict.
4. The max hp is not zero, and the hp is not greater than the max hp.
5. The held runes and the rune memory are each not greater than 999999999, and the rune
   memory is not less than the held runes.

These five tests together gave exactly one match for each of the 20 characters of the
three save files of the test set. Test 1 alone gave two matches for one character, and
test 2 alone gave one match for each character.

### 13.4 The level of the profile summary

The summary of `USER_DATA010` also holds the level of each slot, 0x22 bytes after the
name of the slot (section 4.1):

```
level[i] = USER_DATA010.dataOffset + 16 + 0x195E + i * 0x24C + 0x22
```

This field is **not** 4-byte aligned, because the name before it has a length of 0x22
bytes. Read it as an unaligned `u32`.

This value is the cross-check of the scan. It comes from a different entry of the
container than the player block, so a match of the two is strong evidence that the block
is the block of that character.
