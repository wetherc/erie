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

# --- verdict ---------------------------------------------------------------------

Write-Host ''
if ($script:Failed -eq 0) { Write-Host 'All checks passed.'; exit 0 }
Write-Host "$script:Failed check(s) FAILED."
exit 1
