<#
.SYNOPSIS
  Engine compatibility checks for the ERIE libraries.
.DESCRIPTION
  Runs the pure parsing and crypto logic against synthetic data built in memory. No game
  files, no save files and no network access are needed, so this runs anywhere either
  engine runs. Run it under both engines on Windows:

      powershell -NoProfile -File .\Test-ErCompat.ps1
      pwsh -NoProfile -File .\Test-ErCompat.ps1

  On other platforms only pwsh is available; the Windows-only pieces (the Oodle DLL and
  save-folder discovery) are out of scope here and need a manual check on Windows.

  Exit code 0 means every check passed; 1 means at least one failed.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ERSaveLib.ps1"
. "$PSScriptRoot\ErProfileLib.ps1"
. "$PSScriptRoot\ErArchiveLib.ps1"

$script:Failed = 0
function Assert-Er {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Name)
    if ($Condition) { Write-Host "  ok    $Name" }
    else            { Write-Host "  FAIL  $Name"; $script:Failed++ }
}

Write-Host ("Engine: PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

# --- fixture builders ----------------------------------------------------------

function New-ErTestBnd4 {
    <#  A minimal BND4 with 32-byte entries, the layout Get-ErEntries reads: magic at 0,
        count at 12, entry headers from 0x40, UTF-16LE names, 16-byte MD5 ahead of each
        payload.  #>
    param([Parameter(Mandatory)][hashtable[]]$Entries)

    $count   = $Entries.Count
    $headers = 0x40 + $count * 32
    # built with a loop: piping byte[] values through ForEach-Object unrolls them
    $names = @()
    foreach ($e in $Entries) { $names += , [Text.Encoding]::Unicode.GetBytes($e.Name + [char]0) }
    $nameOff = @(); $p = $headers
    foreach ($n in $names) { $nameOff += $p; $p += $n.Length }
    $dataOff = @()
    foreach ($e in $Entries) { $dataOff += $p; $p += 16 + $e.Data.Length }

    $buf = New-Object byte[] $p
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('BND4'), 0, $buf, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([int]$count), 0, $buf, 12, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $o = 0x40 + $i * 32
        [Array]::Copy([BitConverter]::GetBytes([int64](16 + $Entries[$i].Data.Length)), 0, $buf, $o + 8, 8)
        [Array]::Copy([BitConverter]::GetBytes([int]$dataOff[$i]), 0, $buf, $o + 16, 4)
        [Array]::Copy([BitConverter]::GetBytes([int]$nameOff[$i]), 0, $buf, $o + 20, 4)
        [Array]::Copy($names[$i], 0, $buf, $nameOff[$i], $names[$i].Length)
        [Array]::Copy($Entries[$i].Data, 0, $buf, $dataOff[$i] + 16, $Entries[$i].Data.Length)
        $md5 = [Security.Cryptography.MD5]::Create().ComputeHash([byte[]]$Entries[$i].Data)
        [Array]::Copy($md5, 0, $buf, $dataOff[$i], 16)
    }
    # the comma keeps this one byte[]: a bare $buf unrolls on return, and every later
    # -Bytes coercion would then work on a fresh copy, losing in-place writes
    , $buf
}

function New-ErTestSlot {
    <#  A slot payload carrying one dense inventory array (count + 12-byte records) and,
        ahead of it, one player block shaped the way ErPlayerScan expects.  #>
    param([int]$ItemCount = 32, [string]$Name = 'Testchar', [int]$Level = 42)

    $buf = New-Object byte[] 8192

    # player block: level at $lp, stats/hp below it, runes above, name at +0x34
    $lp = 0x400
    [Array]::Copy([BitConverter]::GetBytes([uint32]$Level), 0, $buf, $lp, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]1000), 0, $buf, $lp + 4, 4)     # runes
    [Array]::Copy([BitConverter]::GetBytes([uint32]5000), 0, $buf, $lp + 8, 4)     # memory
    [Array]::Copy([BitConverter]::GetBytes([uint32]450), 0, $buf, $lp - 0x58, 4)   # hp
    [Array]::Copy([BitConverter]::GetBytes([uint32]500), 0, $buf, $lp - 0x54, 4)   # max hp
    for ($s = 0; $s -lt 8; $s++) {
        [Array]::Copy([BitConverter]::GetBytes([uint32](10 + $s)), 0, $buf, $lp - 0x2C + $s * 4, 4)
    }
    $nb = [Text.Encoding]::Unicode.GetBytes($Name)
    [Array]::Copy($nb, 0, $buf, $lp + 0x34, $nb.Length)

    # inventory: count field then records { handle, qty, index }, goods = 0xB0000000|id
    $cp = 0x1000
    [Array]::Copy([BitConverter]::GetBytes([uint32]$ItemCount), 0, $buf, $cp, 4)
    for ($i = 0; $i -lt $ItemCount; $i++) {
        $o = $cp + 4 + $i * 12
        # 0xB0000000 is a negative Int32 literal in PowerShell; the bit pattern is what
        # matters here, so write it as the signed value.
        [Array]::Copy([BitConverter]::GetBytes([int](0xB0000000 -bor (100 + $i))), 0, $buf, $o, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32](1 + $i % 99)), 0, $buf, $o + 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$i), 0, $buf, $o + 8, 4)
    }
    , $buf
}

# --- BND4 + checksum -----------------------------------------------------------

Write-Host 'BND4 container'
$slotData = New-ErTestSlot
$bnd = New-ErTestBnd4 -Entries @(
    @{ Name = 'USER_DATA000'; Data = $slotData },
    @{ Name = 'USER_DATA001'; Data = (New-Object byte[] 64) }
)
$entries = @(Get-ErEntries -Bytes $bnd)
Assert-Er ($entries.Count -eq 2) 'Get-ErEntries finds both entries'
Assert-Er ($entries[0].Name -eq 'USER_DATA000') 'entry name decodes from UTF-16LE'
Assert-Er ($entries[0].Size -eq 16 + $slotData.Length) 'entry size is read'

Write-Host 'per-entry MD5'
Assert-Er (Test-ErChecksum -Bytes $bnd -Entry $entries[0]) 'fresh checksum verifies'
$bnd[$entries[0].DataOffset + 16]++    # corrupt one payload byte
Assert-Er (-not (Test-ErChecksum -Bytes $bnd -Entry $entries[0])) 'corruption is detected'
Update-ErChecksum -Bytes $bnd -Entry $entries[0]
Assert-Er (Test-ErChecksum -Bytes $bnd -Entry $entries[0]) 'Update-ErChecksum repairs it'

# --- compiled scanners ----------------------------------------------------------

Write-Host 'inventory scan (ErSaveScan)'
$invs = @(Find-ErInventories -Bytes $bnd -Entry $entries[0] -MinCount 20 -MaxCount 3000)
Assert-Er ($invs.Count -eq 1) 'exactly one array found'
Assert-Er ($invs[0].Count -eq 32 -and $invs[0].Live -eq 32) 'count and live match the fixture'
$items = @(Get-ErInventoryItems -Bytes $bnd -Inventory $invs[0])
Assert-Er ($items.Count -eq 32) 'all records enumerate'
Assert-Er ($items[0].ItemId -eq 100 -and $items[0].IsGoods) 'goods handle decodes'

Write-Host 'player-block scan (ErPlayerScan)'
$ds = $entries[0].DataOffset + 16
$de = $entries[0].DataOffset + $entries[0].Size
$hits = @([ErPlayerScan]::Find($bnd, $ds, $de, 42, [Text.Encoding]::Unicode.GetBytes('Testchar')))
Assert-Er ($hits.Count -eq 1) 'exactly one player block found'
Assert-Er (([BitConverter]::ToUInt32($bnd, $hits[0] + 4)) -eq 1000) 'runes read back at +4'
$none = @([ErPlayerScan]::Find($bnd, $ds, $de, 42, [Text.Encoding]::Unicode.GetBytes('Test')))
Assert-Er ($none.Count -eq 0) 'prefix of the name does not match (null-terminator check)'

# --- character table -------------------------------------------------------------

Write-Host 'character table (Get-ErCharacters)'
$threw = $false
try { [void](Get-ErCharacters -Bytes $bnd) } catch { $threw = $true }
Assert-Er $threw 'a file without USER_DATA010 is a clear error'

# USER_DATA010 carries slot names at 0x195E + 0x24C per slot, level 0x22 past the name.
$profData = New-Object byte[] 0x3000
$nb = [Text.Encoding]::Unicode.GetBytes('Frieren')
[Array]::Copy($nb, 0, $profData, 0x195E, $nb.Length)
[Array]::Copy([BitConverter]::GetBytes([uint32]42), 0, $profData, 0x195E + 0x22, 4)
# slot 1: a stale name over an all-zero payload, which must read as unoccupied
$nb2 = [Text.Encoding]::Unicode.GetBytes('Ghost')
[Array]::Copy($nb2, 0, $profData, 0x195E + 0x24C, $nb2.Length)

$slotEntries = @(@{ Name = 'USER_DATA000'; Data = $slotData })
for ($i = 1; $i -le 9; $i++) { $slotEntries += @{ Name = ('USER_DATA00{0}' -f $i); Data = (New-Object byte[] 256) } }
$slotEntries += @{ Name = 'USER_DATA010'; Data = $profData }
$bndChars = New-ErTestBnd4 -Entries $slotEntries
$chars = @(Get-ErCharacters -Bytes $bndChars)
Assert-Er ($chars[0].Name -eq 'Frieren' -and $chars[0].IsOccupied -and $chars[0].Level -eq 42) 'occupied slot reads name and level'
Assert-Er (-not $chars[1].IsOccupied) 'zero payload reads as unoccupied despite a stale name'
Assert-Er ((Resolve-ErSlot -Bytes $bndChars -Character 'fri') -eq 0) 'a unique name prefix resolves to its slot'
$threw = $false
try { [void](Resolve-ErSlot -Bytes $bndChars -Character 'nobody') } catch { $threw = $true }
Assert-Er $threw 'an unknown character name is an error, not a guess'

# --- profile rules ----------------------------------------------------------------

Write-Host 'profile resolution (Resolve-ErProfile)'
# -ModDir pointing nowhere keeps these hermetic: no real install can influence them.
$noMod = Join-Path $PSScriptRoot 'no-such-dir'
$r = Resolve-ErProfile -SavePath 'ER0000.cnv' -ModDir $noMod
Assert-Er ($r.Profile -eq 'convergence') 'a .cnv save resolves to convergence'
$r = Resolve-ErProfile -SavePath 'ER0000.cnv.co2' -ModDir $noMod
Assert-Er ($r.Profile -eq 'convergence') 'a .cnv.co2 save resolves to convergence'
$r = Resolve-ErProfile -SavePath 'ER0000.sl2' -ModDir $noMod
Assert-Er ($r.Profile -eq 'vanilla') 'a .sl2 save with no mod install resolves to vanilla'
$r = Resolve-ErProfile -SavePath 'ER0000.sl2' -ForceProfile convergence -ModDir $noMod
Assert-Er ($r.Profile -eq 'convergence') '-Profile overrides detection'

Write-Host 'weapon ceiling rules (Get-ErWeaponCeiling)'
$profConv = [pscustomobject]@{ Name = 'convergence'; MaxLevel = @{ 100 = 15; 200 = 15 } }
$profVan  = [pscustomobject]@{ Name = 'vanilla';     MaxLevel = @{ 100 = 25 } }
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 100) -eq 15) "the build's own ceiling applies"
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 999) -eq 0) 'a weapon the build does not define gets 0'
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 100 -Requested 10) -eq 10) '-MaxWeaponLevel lowers the ceiling'
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 100 -Requested 20) -eq 15) '-MaxWeaponLevel never raises it'
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 100 -Requested 0) -eq 0) 'a requested 0 means leave everything alone'
Assert-Er ((Get-ErWeaponCeiling -Profile $profVan -BaseId 100 -BaseGameProfile $profConv) -eq 15) '-BaseGame clamps to the lower ceiling'
Assert-Er ((Get-ErWeaponCeiling -Profile $profConv -BaseId 200 -BaseGameProfile $profVan) -eq 0) 'a weapon absent from vanilla clamps to 0 under -BaseGame'

Write-Host 'spirit-ash ladders (Get-ErAshLadders)'
# Ids matter here: a ladder is recognised by its shape inside the goods block spirit
# ashes live in, not by the word "Ashes" in its name, because the ghost-glovewort
# spirits are named after the spirit itself and carry no such word.
$goodsNames = @{ 300 = 'Crimson Tear Flask'; 302 = 'Crimson Tear Flask +1'; 304 = 'Crimson Tear Flask +2' }
foreach ($i in 0..10) {
    $suffix = $(if ($i) { " +$i" } else { '' })
    $goodsNames[203000 + $i] = "Lone Wolf Ashes$suffix"          # grave glovewort
    $goodsNames[258000 + $i] = "Lhutel the Headless$suffix"      # ghost glovewort
}
$goodsNames[204000] = 'Wandering Noble Ashes'                    # no rungs at all
$goodsNames[2000300] = 'Hefty Fire Pot'                          # in the block, no ladder
$ladders = Get-ErAshLadders -GoodsNames $goodsNames
Assert-Er ($ladders.ContainsKey('Lone Wolf Ashes') -and $ladders['Lone Wolf Ashes'].Max -eq 10) 'ladder and its maximum come from the names'
Assert-Er ($ladders['Lone Wolf Ashes'].ByLevel[10] -eq 203010) 'the top level maps to its id'
Assert-Er ($ladders.ContainsKey('Lhutel the Headless') -and $ladders['Lhutel the Headless'].Max -eq 10) 'a ghost-glovewort spirit is a ladder even with no "Ashes" in its name'
Assert-Er (-not $ladders.ContainsKey('Crimson Tear Flask')) 'flasks with +N names are not ashes'
Assert-Er (-not $ladders.ContainsKey('Wandering Noble Ashes')) 'a family with no +N rungs is not a ladder'
Assert-Er (-not $ladders.ContainsKey('Hefty Fire Pot')) 'a good in the ash id block with no ladder is not an ash'
$ix = Get-ErAshIdIndex -Ladders $ladders
Assert-Er ($ix[258007].Family -eq 'Lhutel the Headless' -and $ix[258007].Level -eq 7) 'the id index carries family and level for every rung'
Assert-Er (-not $ix.ContainsKey(302)) 'the id index excludes non-ash "+N" goods'

# --- archive crypto -------------------------------------------------------------

Write-Host 'RSA / DER / path hash (ErArchive)'
foreach ($stem in @('Data0', 'Data1', 'Data2', 'Data3')) {
    $k = ConvertFrom-ErPemRsa -Base64 $script:ErBhdKeys[$stem]
    Assert-Er ($k.Modulus.Length -ge 256 -and $k.Exponent.Length -ge 1) "$stem key parses from DER"
}
# raw modexp against the textbook case n=3233, e=17, d=2753: enc(65) = 65^17 = 2790.
# RsaDecrypt computes c^exp mod n, so inverting 2790 back to 65 takes d, not e.
$blk = New-Object byte[] 256
$blk[254] = 0x0A; $blk[255] = 0xE6                       # 2790 big-endian
$dec = [ErArchive]::RsaDecrypt($blk, [byte[]](0x0C, 0xA1), [byte[]](0x0A, 0xC1))
Assert-Er ($dec.Length -eq 255 -and $dec[254] -eq 65) 'RsaDecrypt matches known modexp'
Assert-Er (([ErArchive]::PathHash('AB', [uint64]133)) -eq (65 * 133 + 66)) 'PathHash matches its definition'

Write-Host 'AES entry decryption'
$plain = New-Object byte[] 32
0..31 | ForEach-Object { $plain[$_] = $_ }
$key = New-Object byte[] 16
0..15 | ForEach-Object { $key[$_] = 0xA0 + $_ }
$aes = [Security.Cryptography.Aes]::Create()
$aes.KeySize = 128; $aes.BlockSize = 128
$aes.Mode = [Security.Cryptography.CipherMode]::ECB
$aes.Padding = [Security.Cryptography.PaddingMode]::None
$aes.Key = $key
$encBuf = New-Object byte[] 32
$encr = $aes.CreateEncryptor()
[void]$encr.TransformBlock($plain, 0, 32, $encBuf, 0)
$encr.Dispose(); $aes.Dispose()
$entry = [pscustomobject]@{
    AesKey = $key
    Ranges = @([pscustomobject]@{ Start = [int64]0; End = [int64]32 })
}
$roundTrip = Unprotect-ErArchiveEntry -Bytes $encBuf -Entry $entry
$same = $true
for ($i = 0; $i -lt 32; $i++) { if ($roundTrip[$i] -ne $i) { $same = $false; break } }
Assert-Er $same 'Unprotect-ErArchiveEntry inverts AES-128-ECB over the declared range'

# --- DCX (DFLT branch) ----------------------------------------------------------

Write-Host 'DCX DFLT (zlib)'
$payload = [Text.Encoding]::ASCII.GetBytes(('erie compatibility ' * 20))
$ms = New-Object IO.MemoryStream
$dsm = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress, $true)
$dsm.Write($payload, 0, $payload.Length); $dsm.Dispose()
$deflated = $ms.ToArray(); $ms.Dispose()
$zlib = New-Object byte[] ($deflated.Length + 2)
$zlib[0] = 0x78; $zlib[1] = 0x9C
[Array]::Copy($deflated, 0, $zlib, 2, $deflated.Length)

function Write-ErTestBE32 { param([byte[]]$b, [int]$o, [uint32]$v)
    $b[$o] = ($v -shr 24) -band 0xFF; $b[$o+1] = ($v -shr 16) -band 0xFF
    $b[$o+2] = ($v -shr 8) -band 0xFF; $b[$o+3] = $v -band 0xFF
}
# header laid out to what Expand-ErDcx reads: DCS at 0x18, DCP at 0x24, DCA at 0x2C,
# payload at DCA + 8
$dcx = New-Object byte[] (0x34 + $zlib.Length)
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('DCX'), 0, $dcx, 0, 3)
Write-ErTestBE32 $dcx 8  0x18                          # DCS offset
Write-ErTestBE32 $dcx 12 0x24                          # DCP offset
Write-ErTestBE32 $dcx 16 0x2C                          # DCA offset
Write-ErTestBE32 $dcx (0x18 + 4) ([uint32]$payload.Length)
Write-ErTestBE32 $dcx (0x18 + 8) ([uint32]$zlib.Length)
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('DFLT'), 0, $dcx, 0x24 + 4, 4)
Write-ErTestBE32 $dcx (0x2C + 4) 8                     # data starts 8 past DCA
[Array]::Copy($zlib, 0, $dcx, 0x34, $zlib.Length)

$inflated = Expand-ErDcx -Bytes $dcx
Assert-Er ([Text.Encoding]::ASCII.GetString($inflated) -eq ('erie compatibility ' * 20)) 'zlib payload round-trips'

# --- pick-one prompts -----------------------------------------------------------
# Both paths are driven by standing in for the one primitive each of them reads through,
# Read-ErLine and Read-ErKey, so neither test needs a person at a keyboard. Which path is
# under test is pinned with ErNoRawKeys rather than left to the environment: run from a
# terminal window the picker would otherwise draw a menu, and the numbered tests would sit
# there waiting for a keystroke nobody is going to press.
#
# The drawn menu still needs a real console to draw on, so it is skipped where there is
# none (a redirected stdout, which is what CI and a captured transcript look like) rather
# than reported as a pass that never ran.

$script:erTestLines = @()
function Read-ErLine {
    param([string]$Prompt = '>')
    if (-not $script:erTestLines.Count) { throw 'the test ran out of scripted answers' }
    $a = $script:erTestLines[0]
    $script:erTestLines = @($script:erTestLines | Select-Object -Skip 1)
    $a
}
function Set-ErTestLines { $script:erTestLines = @($args) }

$script:erTestKeys = @()
function Read-ErKey {
    if (-not $script:erTestKeys.Count) { throw 'the test ran out of scripted keys' }
    $k = $script:erTestKeys[0]
    $script:erTestKeys = @($script:erTestKeys | Select-Object -Skip 1)
    $k
}
function Set-ErTestKeys {
    <#  'Down Down Enter' is three keys; anything that is not a key name is typed one
        character at a time, which is how the search box gets its input.  #>
    param([Parameter(Mandatory)][string]$Spec)
    $named = @{ Down = 'DownArrow'; Up = 'UpArrow'; PgDn = 'PageDown'; PgUp = 'PageUp'
                Home = 'Home'; End = 'End'; Enter = 'Enter'; Esc = 'Escape'
                Bksp = 'Backspace'; Right = 'RightArrow' }
    $keys = @()
    foreach ($s in $Spec.Split(' ')) {
        if ($named.ContainsKey($s)) {
            $keys += New-Object ConsoleKeyInfo ([char]0), ([ConsoleKey]$named[$s]), $false, $false, $false
        }
        else {
            # Virtual key 0 with a character is what a console reports for an ordinary
            # key, and is what the menu treats as search text.
            foreach ($c in $s.ToCharArray()) {
                $keys += New-Object ConsoleKeyInfo $c, ([Enum]::ToObject([ConsoleKey], 0)), $false, $false, $false
            }
        }
    }
    $script:erTestKeys = @($keys)
}

$pickItems = @(0..7 | ForEach-Object { [pscustomobject]@{ Name = "Item $_" } })
$pickItems[7].Name = 'Lhutel the Headless'
$pickLabel = { param($x) $x.Name }

Write-Host 'pick-one prompts, numbered path (Select-ErNumberedMenu)'
$script:ErNoRawKeys = $true          # every pick below goes to the numbered path

function Invoke-ErTestPick {
    param($Items = $pickItems, [int]$Size = 3)
    # 6>$null: the numbered path prints the page it is asking about, which is the whole
    # point of it and pure noise in a test transcript.
    Select-ErItem -Title 'T' -Items $Items -Label $pickLabel -PageSize $Size 6>$null
}

Set-ErTestLines '/Lhutel' '7'
Assert-Er ((Invoke-ErTestPick).Name -eq 'Lhutel the Headless') 'a filter then an absolute number picks that item'
Set-ErTestLines '' '4'
Assert-Er ((Invoke-ErTestPick).Name -eq 'Item 4') 'paging does not renumber the items'
Set-ErTestLines '/Lhutel' '2' '7'
Assert-Er ((Invoke-ErTestPick).Name -eq 'Lhutel the Headless') 'a number filtered off the page is refused, not picked'
Set-ErTestLines '/nothing' '0'
Assert-Er ((Invoke-ErTestPick).Name -eq 'Item 0') 'a filter matching nothing clears itself'
Set-ErTestLines $null
Assert-Er ($null -eq (Invoke-ErTestPick)) 'Esc picks nothing'
Assert-Er ($null -eq (Invoke-ErTestPick -Items @())) 'an empty list picks nothing without asking'
Assert-Er ((Select-ErOption -Prompt 'P' -Options @('only') -Label { param($x) $x }) -eq 'only') 'a single option needs no prompt'

# Which half of Select-ErOption is reachable depends on whether this run can prompt at
# all, so each is checked where it applies rather than one of them being faked.
if (Test-ErInteractive) {
    Set-ErTestLines '1'
    Assert-Er ((Select-ErOption -Prompt 'P' -Options @('a', 'b') -Label { param($x) $x } 6>$null) -eq 'b') `
        'Select-ErOption picks through the same list prompt as everything else'
    Set-ErTestLines $null
    $escaped = Select-ErOption -Prompt 'P' -Options @('a', 'b') -Label { param($x) $x } -AllowEscape 6>$null
    Assert-Er ($null -eq $escaped) 'Esc out of Select-ErOption returns null with -AllowEscape'
    Set-ErTestLines $null
    $cancelled = $false
    try { $null = Select-ErOption -Prompt 'P' -Options @('a', 'b') -Label { param($x) $x } 6>$null }
    catch { $cancelled = $true }
    Assert-Er $cancelled 'Esc out of Select-ErOption cancels the run without -AllowEscape'
}
else {
    $threw = $false
    try { $null = Select-ErOption -Prompt 'P' -Options @('a', 'b') -Label { param($x) $x } -NonInteractiveHint 'pass one of:' 6>$null }
    catch { $threw = ($_.Exception.Message -match 'pass one of:' -and $_.Exception.Message -match 'b') }
    Assert-Er $threw 'with no way to ask, Select-ErOption throws and lists the options'
}

Write-Host 'pick-one prompts, drawn menu (Select-ErDrawnMenu)'
$script:ErNoRawKeys = $false
if (-not (Test-ErRawKeys)) {
    Write-Host '  skipped - no console to draw on (run this in a terminal window to cover it)'
}
else {
    $drawn = @(0..29 | ForEach-Object { [pscustomobject]@{ Name = "Item $_" } })
    $drawn[23].Name = 'Lhutel the Headless'
    function Invoke-ErTestDraw {
        param($Items = $drawn, [int]$Size = 8, [string]$Title = 'T')
        Select-ErDrawnMenu -Title $Title -Items $Items -Label $pickLabel -PageSize $Size
    }

    Set-ErTestKeys 'Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 0') 'Enter takes the item the highlight starts on'
    Set-ErTestKeys 'Down Down Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 2') 'the arrow keys move the highlight'
    Set-ErTestKeys 'Down Right Down Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 2') 'a key the menu does not use moves nothing'
    Set-ErTestKeys 'Up Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 29') 'up from the first item wraps to the last'
    Set-ErTestKeys 'End Up Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 28') 'End jumps to the last item'
    Set-ErTestKeys 'PgDn PgDn PgUp Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 8') 'PgDn and PgUp move by the page'
    Set-ErTestKeys 'End PgDn Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 29') 'PgDn at the end stays there'
    Set-ErTestKeys 'PgUp Home Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 0') 'Home returns to the first item'
    Set-ErTestKeys 'Down Down Down Down Down Down Down Down Down Down Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 10') 'the view scrolls past the page to follow the highlight'
    Set-ErTestKeys 'headless Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Lhutel the Headless') 'typing searches, case-insensitively and anywhere in the label'
    Set-ErTestKeys 'Lhutelx Bksp Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Lhutel the Headless') 'Backspace widens the search again'
    Set-ErTestKeys 'Item Down Enter'
    Assert-Er ((Invoke-ErTestDraw).Name -eq 'Item 1') 'the highlight starts over when the search changes'
    Set-ErTestKeys 'zzz Enter Esc'
    Assert-Er ($null -eq (Invoke-ErTestDraw)) 'Enter picks nothing while nothing matches'
    Set-ErTestKeys 'Esc'
    Assert-Er ($null -eq (Invoke-ErTestDraw)) 'Esc picks nothing'
    Set-ErTestKeys 'Down Down Down Enter'
    Assert-Er ((Invoke-ErTestDraw -Items @($drawn[0..2])).Name -eq 'Item 0') 'a short list wraps at its own end, not the page end'
    Set-ErTestKeys 'Enter'
    Assert-Er ((Invoke-ErTestDraw -Items @($drawn[0])).Name -eq 'Item 0') 'a one-item menu answers'
    Set-ErTestKeys 'Enter'
    Assert-Er ((Invoke-ErTestDraw -Size 500).Name -eq 'Item 0') 'a page taller than the window is clamped to it'

    # Where the frame goes matters as much as what it returns: it is wiped on the way out,
    # and whatever is printed next has to land where the menu started, not on top of it.
    $before = [Console]::CursorTop
    Set-ErTestKeys 'Enter'; $null = Invoke-ErTestDraw
    Assert-Er ([Console]::CursorTop -eq $before) 'the frame is wiped and the cursor returns to where it started'
    $before = [Console]::CursorTop
    Set-ErTestKeys 'Esc'; $null = Invoke-ErTestDraw
    Assert-Er ([Console]::CursorTop -eq $before) 'Esc leaves the cursor where Enter does'

    # At the bottom of the buffer, printing the frame is itself what scrolls, which is why
    # the menu records where the frame landed only after making room for it.
    while ([Console]::CursorTop -lt [Console]::BufferHeight - 3) { [Console]::WriteLine() }
    Set-ErTestKeys 'Down Enter'
    Assert-Er ((Invoke-ErTestDraw -Title 'BOTTOM').Name -eq 'Item 1') 'a frame drawn at the bottom of the buffer still answers'
}

# --- verdict ---------------------------------------------------------------------

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'All checks passed.'; exit 0 }
Write-Host "$script:Failed check(s) FAILED."
exit 1
