# ERIE: Elden Ring Inventory Editor

ERIE is a command line inventory editor for Elden Ring. It supports both vanilla save editing and Convergence mod saves.

With ERIE, you can modify the quantity of any currently-held consumable, can modify the upgrade level of any owned weapon, and can modify your character's held runes. It does not support adding new items to your character's inventory. This mostly was created so that I don't have to grind for hours on end, not as a cheat engine.

Obviously don't use this if you plan to play online; it's a violation of the EULA and should get your account an online play restriction.

## Installation and usage

You need PowerShell. This works on Windows, sorry SteamOS


### Requirements

**To edit saves**:

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- Elden Ring must not be running.

**To regenerate the reference tables**:

- `oo2core_6_win64.dll` from the game install, to decompress the game archives.
- Node.js v23 or newer on `PATH`, for ZSTD-compressed `regulation.bin` files (current game patches). The editor itself doesn't need Node.


### Installation

1. Put this folder anywhere **outside** `%APPDATA%\EldenRing\`
2. Allow the scripts to run in your current PowerShell session:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile
```

Or, for PowerShell 7 (it keeps its own execution policy, separate from 5.1):

```powershell
pwsh -ExecutionPolicy Bypass -NoProfile
```

3. Check the install by listing what is in your saves:

```powershell
.\Show-ErInventory.ps1
```

It finds the save folder under `%APPDATA%\EldenRing\<steamId64>\`, asks which save file to read if there is more than one and will list out all characters that it discovered.

---

## Choosing the save, build, and character

Every script here accepts the following arguments:

| Argument | Meaning |
|---|---|
| `-Path` | An explicit save file. Skips automated discovery. |
| `-SaveFolder` | Which `%APPDATA%\EldenRing\<steamId64>` folder to use. |
| `-Save` | Which save inside it, by file name (e.g., `ER0000.cnv`). |
| `-Profile` | Force `vanilla` or `convergence` instead of detecting the build. |
| `-ModDir` | Where The Convergence is installed, if not in a usual location. |
| `-BaseGame` | Restrict to what the base game supports. See below. |
| `-Character` | Which character's inventory to modify, by name or unique prefix (case-insensitive). |
| `-Slot` | Who to act on, by slot index. This is probably not an argument you want to use. |

All of the above are optional. If anything is ambiguous during discovery, you'll be explicitly prompted. Backups (`.bak-*`) are never used for editing.

**Two things worth knowing before your first run:**

- **`-Save ER0000` may be ambiguous.** `ER0000.sl2` and `ER0000.cnv` are both present in a modded install: `.sl2` is the vanilla game save file; `.cnv` is the Convergence mod save. Always specify a file extension when using this argument
- **Nothing ever defaults to a slot number.**  Select by `-Character` wherever you can. Despite this being an argument that exists, it's mostly for me. It's not useful. Don't use it.

The build is detected from the save extension, then from the mod's `altsaves.toml`, then from whether a Convergence install exists. The script will always show whether it interpreted the save data as base game or Convergence: pay attention to that. If the guess is wrong, item names will be wrong and you'll have no idea what you're actually editing. Other hijinks may ensue, I don't really know.

---

## Usage

### Look at a save

```powershell
.\Show-ErInventory.ps1
```

Lists every character, every item array in each slot, and the consumables each character has. Each slot also gets a line with its level, the runes it is carrying and its rune memory. Weapons and armour show as `<cat 0x8 id 524>` here, for full item information you need to use `Show-ErEquipment.ps1`.

Filters: `-Character`, `-Slot`, `-NameLike`, `-ItemId`, `-GoodsOnly`.

```powershell
.\Show-ErInventory.ps1 -Save ER0000.cnv -Character JohnEldenRing -NameLike '*Stone*' -GoodsOnly
```

### Look at weapons, armour and spirit ashes

```powershell
.\Show-ErEquipment.ps1 -Save ER0000.cnv -Character JohnEldenRing
```

This reads the GaItem table and prints each weapon with its current level and the ceiling **this build** gives the weapon (Convergence changes the weapon level upgrade system). `[not upgradeable]` means the build gives that weapon no upgrade path. Shocker. Add `-IncludeArmour` for armour. Armour has no upgrade path and can't be edited, but I was already decoding the item tables so displaying it here wasn't a huge deal.

### Change stack quantities

Everything dry runs by default (it will preview changes, but won't actually modify your save file). Adding the `-Apply` flag writes the changes back to your save.

```powershell
.\Edit-ErItemQuantity.ps1 -Save ER0000.cnv -Character Spantz -ItemId 10101,10105 -Quantity 999
```

```powershell
.\Edit-ErItemQuantity.ps1 -Save ER0000.cnv -Character Spantz -ItemId 10101,10105 -Quantity 999 -Apply
```

You can select items with `-ItemId`, `-NameLike`, or both (I guess, although that's redundant); one or the other is always required. Quantity range is 1 through 999. Only items the character already
holds are edited, this will never add new items that your character doesn't already hold some number of.

Only goods are edited: consumables, materials, key items. Weapon and armour records carry a dynamic handle instead of an item id, so `-ItemId` can't select them and they are never touched.

On `-Apply` the script takes a timestamped backup next to the save, patches the save, recomputes the slot MD5, and re-verifies the edits from disk.

### Change the runes a character is carrying

```powershell
.\Edit-ErRunes.ps1 -Save ER0000.cnv -Character Spantz -Runes 999999999
```

```powershell
.\Edit-ErRunes.ps1 -Save ER0000.cnv -Character Spantz -Runes 999999999 -Apply
```

Dry runs by default, same as everything else. `-Runes` is the new balance, 0 through 999,999,999 (the game's own ceiling). Add `-Add` to treat the number as an amount to add to what the character already holds instead, capped at the same ceiling.

This is the rune counter in the corner of the HUD. It is not a Rune item sitting in the inventory: those are goods, so they belong to `Edit-ErItemQuantity.ps1`.

The save also tracks *rune memory*, the lifetime total of every rune the character has earned. When the new balance would be higher than that total, rune memory is raised to match, because the game never writes a save holding more runes than were ever earned. `-SkipRuneMemory` leaves it alone.

`-BaseGame` is accepted here for consistency but does nothing: a rune count is the same plain number in either build, so there is nothing that could fail to load without the mod.

The runes live in a structure that nothing in the file points at, so it is located by a scan on every run: the character's level (cross-checked against the profile summary), their name, and a sane stat and HP block all have to line up before anything is written. If no block matches, the script says so for that character and writes nothing rather than guessing an offset.

### Raise weapon and spirit-ash levels

```powershell
.\Edit-ErUpgrade.ps1 -Save ER0000.cnv -Character Spantz
.\Edit-ErUpgrade.ps1 -Save ER0000.cnv -Character Spantz -Apply
```

This will upgrade all weapons / spirit ashes that your chosen character has. You don't get to choose, because I don't want to choose. I just want upgraded weapons. The level that each individual weapon gets upgraded to will be based on its normal upgrade path (somber weapons get capped at +10; regular ones go to +25; things with the Convergence mod do... something else. +15 or whatever, IDK).

Options: `-MaxWeaponLevel <n>` caps the result further ("no higher than", if you want to keep your weapons at an appropriate level for your overall progression); `-SkipWeapons` and `-SkipSpiritAshes` to only upgrade weapons or only upgrade ashes. `-Slot` may select several characters; each one gets its own section in the plan.

### Interactive editor

```powershell
.\Edit-ErSave.ps1
.\Edit-ErSave.ps1 -Save ER0000.cnv -Character Frieren
```

I hate PowerShell, so we got an interactive tool that lets me pretend this is written with literally any other framework. Pick a character, then weapons (set level), spirit ashes (set level), consumables (set quantity) or runes (set the count in hand). Every list works the same way: the up and down arrows move the highlight, PgUp/PgDn and Home/End jump around, typing anything searches as you type, Backspace deletes a letter of the search, Enter takes the highlighted item and Esc goes back. Quit from the menu, or press Esc there.

To change a pile of things at once, tick them: Tab ticks the highlighted row and moves down, Shift+Tab ticks and moves up, Ctrl+A ticks everything the search is showing, Ctrl+D unticks everything, and Enter takes the lot. Ticks are remembered across searches, so "999 of every smithing stone and every grace-restoring thing" is: type `smithing`, Ctrl+A, backspace it out, type the next thing, Ctrl+A, Enter. Then answer one prompt with the quantity, and confirm once.

Levels work the same way for weapons and spirit ashes, with the obvious caveat handled for you: one level is asked for and each item takes as much of it as its own ceiling allows, so asking for +25 across a mixed pile maxes the somber weapons at +10 rather than refusing the whole thing. Anything that cannot take the value at all — not upgradeable, not in the base game under `-BaseGame`, already at the value — is listed and left alone. The whole batch is one plan, one confirmation and one write: if any item has moved under the tool since the list was read, nothing at all is written.

If you are somewhere that cannot draw a menu — the ISE, or with the output piped to a file — it falls back to the old numbered lists on its own: type the number to pick, Enter for the next page, `p` for the previous one, `/text` to filter, `/` to clear the filter, Esc to go back. Ticking works there too: a number ticks it, `3-9` ticks a run, `*` ticks everything shown, `-` clears, `d` is done. The numbers next to items are positions in the whole list, not the page, so they mean the same thing before and after a search either way.

The header above the menu shows the selected character's level, runes in hand and rune memory. Raising rune memory alongside the runes is offered as its own confirmation rather than folded into the rune write, because a confirmation that named one field should not quietly change a second one.

One backup is taken before the first write of the session, and the save file is re-checked before every write and not just at startup.

Options: `-PageSize` sets the list length.

---

## Regenerating the reference tables

Run these after a game patch or a mod update. They rewrite `data/<profile>/`.

```powershell
.\Export-ErNames.ps1 -Profile convergence
```

```powershell
.\Export-ErParamData.ps1 -Profile convergence
```

Use `-Profile vanilla` for the base game. Both accept `-GameDir`, `-ModDir` and `-OodleDll` if your install is not in the default location.

`Export-ErNames.ps1` writes the id:name tables (`goodsnames.tsv`, `weaponnames.tsv`, `protectornames.tsv`, `accessorynames.tsv`, `gemnames.tsv`). `Export-ErParamData.ps1` writes `paramids.tsv` (which ids exist) and `weaponlevels.tsv` (how far each weapon upgrades).

Names and param ids are kept separate because mods leave stale vanilla data lying around. `paramids.tsv` is used for all item validation.

Regenerate after **any** mod update. The Convergence mod renames a subset of vanilla ids, and a stale table will report the wrong item for an ID rather than failing. This isn't the worst thing in the world, it'll just be confusing next time you launch the game after the mis-mapped edit.

---

## Checking an engine

```powershell
.\Test-ErCompat.ps1
```

This runs the parsing and crypto logic against synthetic data built in memory. It needs no game files and no saves. Run it under both engines after a PowerShell upgrade. Exit code 0 means every check passed.

---

## Troubleshooting

**"No Elden Ring save folder found."** Pass `-SaveFolder` or `-Path` explicitly. The default search is `%APPDATA%\EldenRing\`.

**"Elden Ring / ME3 is running."** Close the game. Quitting Elden Ring rewrites the save from memory and would discard everything written while it was up.

**"'ER0000' matches more than one save."** Give the extension: `-Save ER0000.cnv` or `-Save ER0000.sl2`.

**The profile line names the wrong build.** Override it with `-Profile vanilla` or `-Profile convergence`.

**"no item array found" for a character.** The slot may not expose an array that the finder recognizes. File a bug probably? Or just move on with life

**Item names look wrong.** Regenerate the tables for that profile. The Convergence mod renames only a subset of vanilla ids and leaves the rest with old names.

**The game shows items the file does not.** Your save might be out of date with a Steam Cloud save.