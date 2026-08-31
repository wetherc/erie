<#
  ErArchiveLib.ps1: reading FromSoftware's packaged formats.

  Everything here is about getting AT the game's own data files. It knows nothing about
  save files; ERSaveLib.ps1 is the counterpart for those.

    DCX      compression wrapper (Oodle Kraken or zlib)
    BND4     archive of files, used for msgbnd and regulation.bin
    FMG      id -> localised string table
    BHD5/BDT the game's encrypted archives (Data0-3, DLC)
    PARAM    a regulation table; only ROW IDS are read, which needs no paramdef

  Dot-source this: . "$PSScriptRoot\ErArchiveLib.ps1"
#>
Set-StrictMode -Version 2

# ==============================================================================
#  BAKED-IN CONSTANTS
# ==============================================================================
# These are FromSoftware's own public keys and hash rules, recovered by the modding
# community and stable across every Elden Ring patch to date. They are literals here so
# that nothing this toolkit does needs network access at run time.
#
# IF A GAME PATCH BREAKS ARCHIVE READING, THIS IS THE BLOCK A DEVELOPER UPDATES.
# Sources to re-derive them from:
#   BHD5 RSA keys + path hash:  github.com/Ekey/ER.BDT.Tool  (ER.Unpacker/FileSystem)
#   regulation AES key:         github.com/JKAnderson/SoulsFormats  (Util/SFUtil.cs)

# One RSA public key per archive; the .bhd is raw-modexp "decrypted" with it. Stored as
# the base64 body of a PEM RSAPublicKey (DER SEQUENCE { INTEGER modulus, INTEGER exp }).
$script:ErBhdKeys = @{
    'Data0' = 'MIIBCwKCAQEA9Rju2whruXDVQZpfylVEPeNxm7XgMHcDyaaRUIpXQE0qEo+6Y36LP0xpFvL0H0kKxHwpuISsdgrnMHJ/yj4S61MWzhO8y4BQbw/zJehhDSRCecFJmFBz3I2JC5FCjoK+82xd9xM5XXdfsdBzRiSghuIHL4qk2WZ/0f/nK5VygeWXn/oLeYBLjX1S8wSSASza64JXjt0bP/i6mpV2SLZqKRxo7x2bIQrR1yHNekSF2jBhZIgcbtMBxjCywn+7p954wjcfjxB5VWaZ4hGbKhi1bhYPccht4XnGhcUTWO3NmJWslwccjQ4ksutLq3uRjLMM0IeTkQO6Pv8/R7UNFtdCWwIERzH8IQ=='
    'Data1' = 'MIIBCwKCAQEAxaBCHQJrtLJiJNdG9nq3deA9sY4YCZ4dbTOHO+v+YgWRMcE6iK6oZIJq+nBMUNBbGPmbRrEjkkH9M7LAypAFOPKC6wMHzqIMBsUMuYffulBuOqtEBD11CAwfx37rjwJ+/1tnEqtJjYkrK9yyrIN6Y+jy4ftymQtjk83+L89pvMMmkNeZaPON4O9q5M9PnFoKvK8eY45ZV/Jyk+Pe+xc6+e4h4cx8ML5U2kMM3VDAJush4z/05hS3/bC4B6K9+7dPwgqZgKx1J7DBtLdHSAgwRPpijPeOjKcAa2BDaNp9Cfon70oC+ZCB+HkQ7FjJcF7KaHsH5oHvuI7EZAl2XTsLEQIENa/2JQ=='
    'Data2' = 'MIIBDAKCAQEA0iDVVQ230RgrkIHJNDgxE7I/2AaH6Li1Eu9mtpfrrfhfoK2e7y4OWU+lj7AGI4GIgkWpPw8JHaV970Cr6+sTG4Tr5eMQPxrCIH7BJAPCloypxcs2BNfTGXzm6veUfrGzLIDp7wy24lIA8r9ZwUvpKlN28kxBDGeCbGCkYeSVNuF+R9rN4OAMRYh0r1Q950xc2qSNloNsjpDoSKoYN0T7u5rnMn/4mtclnWPVRWU940zr1rymv4Jc3umNf6cT1XqrS1gSaK1JWZfsSeD6Dwk3uvquvfY6YlGRygIlVEMAvKrDRMHylsLtqqhYkZNXMdy0NXopf1rEHKy9poaHEmJldwIFAP////8='
    'Data3' = 'MIIBCwKCAQEAvRRNBnVq3WknCNHrJRelcEA2v/OzKlQkxZw1yKll0Y2Kn6G9ts94SfgZYbdFCnIXy5NEuyHRKrxXz5vurjhrcuoYAI2ZUhXPXZJdgHywac/i3S/IY0V/eDbqepyJWHpP6I565ySqlol1p/BScVjbEsVyvZGtWIXLPDbx4EYFKA5B52uK6Gdz4qcyVFtVEhNoMvg+EoWnyLD7EUzuB2Khl46CuNictyWrLlIHgpKJr1QD8a0ld0PDPHDZn03q6QDvZd23UW2d9J+/HeBt52j08+qoBXPwhndZsmPMWngQDaik6FM7EVRQetKPi6h5uprVmMAS5wR/jQIVTMpTj/zJdwIEXszeQw=='
}
# The DLC archive reuses Data0's key.
$script:ErBhdKeys['DLC'] = $script:ErBhdKeys['Data0']

# regulation.bin: AES-256-CBC, IV = the file's first 16 bytes, no padding.
$script:ErRegulationKey = [byte[]]@(
    0x99,0xBF,0xFC,0x36,0x6A,0x6B,0xC8,0xC6,0xF5,0x82,0x7D,0x09,0x36,0x02,0xD6,0x76,
    0xC4,0x28,0x92,0xA0,0x1C,0x20,0x7F,0xB0,0x24,0xD3,0xAF,0x4E,0x49,0x3F,0xEF,0x99)

# BHD5 path hash: 64-bit, hash = char + 133 * hash.
$script:ErPathHashPrime = 133

# ==============================================================================
#  Oodle
# ==============================================================================

function Initialize-ErOodle {
    <#  Binds oo2core_6_win64.dll from the game install. DllImport needs a compile-time
        literal path, so the type is generated for whichever path is bound first.  #>
    param([Parameter(Mandatory)][string]$OodleDll)
    if ('OodleN' -as [type]) { return }
    if (-not (Test-Path $OodleDll)) { throw "Oodle DLL not found: $OodleDll" }
    $lit = $OodleDll.Replace([string][char]92, [string][char]92 + [string][char]92)
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class OodleN {
  [DllImport("$lit", CallingConvention=CallingConvention.Cdecl)]
  public static extern IntPtr OodleLZ_Decompress(
    byte[] compBuf, IntPtr compBufSize, byte[] rawBuf, IntPtr rawLen,
    int fuzzSafe, int checkCRC, int verbosity,
    IntPtr decBufBase, IntPtr decBufSize, IntPtr fpCallback, IntPtr callbackUserData,
    IntPtr decoderMemory, IntPtr decoderMemorySize, int threadPhase);
}
"@
}

# ==============================================================================
#  DCX
# ==============================================================================

function Read-ErBE32 {
    param([byte[]]$b, [int]$o)
    [uint32]$b[$o] * 16777216 + [uint32]$b[$o+1] * 65536 + [uint32]$b[$o+2] * 256 + [uint32]$b[$o+3]
}

function Expand-ErDcx {
    <#  Unwraps a DCX. Two payload methods appear in Elden Ring: KRAK (Oodle Kraken, used
        for msgbnd and most game files) and DFLT (raw zlib, used by regulation.bin).
        The DCX header is BIG-endian, unlike everything inside it.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 3) -ne 'DCX') { throw 'Not a DCX file' }
    $dcsOff  = Read-ErBE32 $Bytes 8
    $dcpOff  = Read-ErBE32 $Bytes 12
    $dcaOff  = Read-ErBE32 $Bytes 16
    $uncSize = Read-ErBE32 $Bytes ($dcsOff + 4)
    $cmpSize = Read-ErBE32 $Bytes ($dcsOff + 8)
    $method  = [Text.Encoding]::ASCII.GetString($Bytes, $dcpOff + 4, 4)
    $dataOff = $dcaOff + (Read-ErBE32 $Bytes ($dcaOff + 4))

    $comp = New-Object byte[] $cmpSize
    [Array]::Copy($Bytes, $dataOff, $comp, 0, $cmpSize)
    $out = New-Object byte[] $uncSize

    if ($method -eq 'KRAK') {
        if (-not ('OodleN' -as [type])) { throw 'Oodle not initialised - call Initialize-ErOodle first' }
        $r = [OodleN]::OodleLZ_Decompress($comp, [IntPtr]$cmpSize, $out, [IntPtr]$uncSize,
                1, 0, 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero,
                [IntPtr]::Zero, [IntPtr]::Zero, 3)
        if ([int64]$r -ne [int64]$uncSize) { throw "Oodle decompress failed ($r of $uncSize)" }
    }
    elseif ($method -eq 'DFLT') {
        # zlib stream: 2-byte header then raw deflate.
        $ms = New-Object IO.MemoryStream (, $comp)
        [void]$ms.Seek(2, 'Begin')
        $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $got = 0
        while ($got -lt $uncSize) {
            $n = $ds.Read($out, $got, $uncSize - $got)
            if ($n -le 0) { break }
            $got += $n
        }
        $ds.Dispose(); $ms.Dispose()
        if ($got -ne $uncSize) { throw "zlib decompress short ($got of $uncSize)" }
    }
    elseif ($method -eq 'ZSTD') {
        $out = Expand-ErZstd -Bytes $comp -ExpectedSize $uncSize
    }
    else { throw "Unsupported DCX method '$method'" }

    $out
}

function Expand-ErZstd {
    <#  ZSTD arrived in Elden Ring with the later patches and is what regulation.bin now
        uses. .NET Framework has no zstd decoder and Windows ships no zstd library, so
        this shells out to Node, which has had zlib.zstdDecompressSync built in since v23.

        This is an EXPORT-TIME dependency only, in the same class as the game's Oodle DLL:
        it runs when a developer regenerates data/<profile>/, never when the save editor
        itself runs. Nothing in the interactive tool reaches this code path.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [int]$ExpectedSize = 0)

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        throw 'ZSTD payload needs Node.js (v23+) on PATH to decompress. Install Node, or regenerate the data tables on a machine that has it - the save editor itself does not need this.'
    }

    $inFile  = [IO.Path]::GetTempFileName()
    $outFile = [IO.Path]::GetTempFileName()
    # The script goes in a file rather than `node -e`: PowerShell strips the inner quotes
    # out of an inline argument, which breaks require("zlib").
    $jsFile  = [IO.Path]::GetTempFileName() + '.js'
    try {
        [IO.File]::WriteAllBytes($inFile, $Bytes)
        $js = 'const z = require("zlib"), f = require("fs");' + [Environment]::NewLine +
              'f.writeFileSync(process.argv[3], z.zstdDecompressSync(f.readFileSync(process.argv[2])));'
        [IO.File]::WriteAllText($jsFile, $js)
        $nodeOut = & $node.Source $jsFile $inFile $outFile 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "node zstd decompress failed: $nodeOut" }
        $result = [IO.File]::ReadAllBytes($outFile)
        if ($ExpectedSize -gt 0 -and $result.Length -ne $ExpectedSize) {
            throw "zstd decompress size mismatch ($($result.Length) of $ExpectedSize)"
        }
        $result
    }
    finally {
        Remove-Item -LiteralPath $inFile, $outFile, $jsFile -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
#  BND4
# ==============================================================================

function Get-ErBnd4Files {
    <#  Returns leafName -> byte[] for every file in a BND4.

        The entry stride is NOT fixed: it is declared at 0x20 as fileHeaderSize. Save
        files use 32-byte entries, msgbnd and regulation use 36 (they carry an extra id
        field). The wrong stride misattributes every file without reporting an error, so
        the stride is read rather than assumed and an unrecognised one is an error.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'BND4') { throw 'Not a BND4 container' }
    $count  = [BitConverter]::ToInt32($Bytes, 12)
    $stride = [int][BitConverter]::ToInt64($Bytes, 0x20)

    # PowerShell variable names are CASE-INSENSITIVE, so these must not differ from the
    # per-entry values below by case alone: $dataField/$doff would be one variable.
    if ($stride -eq 36)     { $dataField = 24; $nameField = 32 }
    elseif ($stride -eq 32) { $dataField = 16; $nameField = 20 }
    else                    { throw "Unhandled BND4 entry stride $stride" }

    $out = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $o = 0x40 + $i * $stride
        $size = [BitConverter]::ToInt64($Bytes, $o + 8)
        $doff = [BitConverter]::ToInt32($Bytes, $o + $dataField)
        $noff = [BitConverter]::ToInt32($Bytes, $o + $nameField)
        $sb = New-Object Text.StringBuilder
        $cur = $noff
        while ($true) {
            $c = [BitConverter]::ToUInt16($Bytes, $cur)
            if ($c -eq 0) { break }
            [void]$sb.Append([char]$c); $cur += 2
        }
        $leaf = $sb.ToString().Split('\')[-1].Split('/')[-1]
        if ($out.ContainsKey($leaf)) { continue }
        $buf = New-Object byte[] $size
        [Array]::Copy($Bytes, $doff, $buf, 0, $size)
        $out[$leaf] = $buf
    }
    $out
}

# ==============================================================================
#  FMG
# ==============================================================================

function Read-ErFmgNames {
    <#  FMG v2: id -> UTF-16LE string.
        header: 0x0C groupCount, 0x10 stringCount, 0x18 (u64) offset table
        groups: 16 bytes each from 0x28 -> { offsetIndex, firstId, lastId, pad }  #>
    param([Parameter(Mandatory)][byte[]]$Fmg, [string]$Label = 'FMG')

    $out = @{}
    if ($Fmg[2] -ne 2) { throw "Unexpected FMG version $($Fmg[2]) in $Label" }
    $groupCount  = [BitConverter]::ToInt32($Fmg, 0x0C)
    $stringCount = [BitConverter]::ToInt32($Fmg, 0x10)
    $offTable    = [BitConverter]::ToInt64($Fmg, 0x18)

    # Sanity: the last group's offsetIndex + span must equal stringCount, otherwise the
    # group table is being read at the wrong stride and every name is misattributed.
    if ($groupCount -gt 0) {
        $lo = 0x28 + ($groupCount - 1) * 16
        $end = [BitConverter]::ToInt32($Fmg, $lo) +
               ([BitConverter]::ToInt32($Fmg, $lo + 8) - [BitConverter]::ToInt32($Fmg, $lo + 4) + 1)
        if ($end -ne $stringCount) { throw "$Label group table inconsistent ($end vs $stringCount strings)" }
    }

    for ($g = 0; $g -lt $groupCount; $g++) {
        $o = 0x28 + $g * 16
        $idx   = [BitConverter]::ToInt32($Fmg, $o)
        $first = [BitConverter]::ToInt32($Fmg, $o + 4)
        $last  = [BitConverter]::ToInt32($Fmg, $o + 8)
        for ($id = $first; $id -le $last; $id++) {
            $so = [BitConverter]::ToInt64($Fmg, $offTable + ($idx + $id - $first) * 8)
            if ($so -eq 0) { continue }
            $sb = New-Object Text.StringBuilder
            $cur = [int]$so
            while ($true) {
                $c = [BitConverter]::ToUInt16($Fmg, $cur)
                if ($c -eq 0) { break }
                [void]$sb.Append([char]$c); $cur += 2
            }
            if ($sb.Length) { $out[$id] = $sb.ToString() }
        }
    }
    $out
}

# ==============================================================================
#  BHD5 / BDT: the game's own archives
# ==============================================================================
# The .bhd is a RSA-encrypted index; the .bdt beside it holds the payloads. Files are
# addressed by a 64-bit hash of their in-game path, never by name, so extracting one
# means hashing the path you want and looking it up. There is no way to enumerate the
# real names from the archive itself.
#
# RSA here is a raw modular exponentiation with the PUBLIC key, with no padding scheme. Each
# 256-byte ciphertext block yields 255 plaintext bytes, left-zero-padded.

if (-not ('ErArchive' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Numerics' @'
using System;
using System.Numerics;

public static class ErArchive
{
    // Raw public-key modexp over the whole .bhd. Compiled because a 7 MB archive is
    // ~28,000 modexps and PowerShell would take minutes.
    public static byte[] RsaDecrypt(byte[] cipher, byte[] modulusBE, byte[] exponentBE)
    {
        BigInteger m = new BigInteger(ToLE(modulusBE));
        BigInteger e = new BigInteger(ToLE(exponentBE));

        int inBlock = 256, outBlock = 255;
        int blocks = cipher.Length / inBlock;
        byte[] outp = new byte[blocks * outBlock];

        byte[] blk = new byte[inBlock];
        for (int i = 0; i < blocks; i++)
        {
            Array.Copy(cipher, i * inBlock, blk, 0, inBlock);
            BigInteger c = new BigInteger(ToLE(blk));
            byte[] p = BigInteger.ModPow(c, e, m).ToByteArray();   // little-endian
            int n = p.Length;
            while (n > 0 && p[n - 1] == 0) n--;                    // drop sign byte / zeros
            if (n > outBlock) n = outBlock;
            // write big-endian, right-aligned in the block
            for (int k = 0; k < n; k++)
                outp[i * outBlock + outBlock - 1 - k] = p[k];
        }
        return outp;
    }

    // BigInteger wants little-endian and unsigned, so reverse and append a zero byte.
    static byte[] ToLE(byte[] be)
    {
        byte[] le = new byte[be.Length + 1];
        for (int i = 0; i < be.Length; i++) le[i] = be[be.Length - 1 - i];
        return le;
    }

    public static ulong PathHash(string path, ulong prime)
    {
        ulong h = 0;
        for (int i = 0; i < path.Length; i++) h = path[i] + prime * h;
        return h;
    }
}
'@
}

function ConvertFrom-ErPemRsa {
    <#  Splits a PEM RSAPublicKey body into big-endian modulus and exponent byte arrays.
        DER: SEQUENCE { INTEGER modulus, INTEGER publicExponent }  #>
    param([Parameter(Mandatory)][string]$Base64)

    $der = [Convert]::FromBase64String(($Base64 -replace '\s', ''))
    $p = 0

    # DER length: short form is one byte; long form is 0x80|n followed by n big-endian
    # bytes. These keys use the 2-byte long form, but both are handled.
    function Read-DerLen {
        param([byte[]]$D, [ref]$Pos)
        $b = $D[$Pos.Value]; $Pos.Value++
        if ($b -lt 0x80) { return [int]$b }
        $n = $b -band 0x7F; $v = 0
        for ($k = 0; $k -lt $n; $k++) { $v = $v * 256 + $D[$Pos.Value]; $Pos.Value++ }
        [int]$v
    }

    if ($der[$p] -ne 0x30) { throw 'RSA key: expected SEQUENCE' }
    $p++; [void](Read-DerLen -D $der -Pos ([ref]$p))
    if ($der[$p] -ne 0x02) { throw 'RSA key: expected modulus INTEGER' }
    $p++; $mlen = Read-DerLen -D $der -Pos ([ref]$p)
    $mod = $der[$p..($p + $mlen - 1)]; $p += $mlen
    if ($der[$p] -ne 0x02) { throw 'RSA key: expected exponent INTEGER' }
    $p++; $elen = Read-DerLen -D $der -Pos ([ref]$p)
    $exp = $der[$p..($p + $elen - 1)]

    [pscustomobject]@{ Modulus = [byte[]]$mod; Exponent = [byte[]]$exp }
}

function Get-ErBhdIndex {
    <#  RSA-decrypts one .bhd and returns nameHash -> entry. Entries carry the payload's
        offset and size in the sibling .bdt, plus an optional AES key covering byte
        ranges of the payload.  #>
    param([Parameter(Mandatory)][string]$BhdPath)

    $stem = [IO.Path]::GetFileNameWithoutExtension($BhdPath)
    if (-not $script:ErBhdKeys.ContainsKey($stem)) { throw "No RSA key known for archive '$stem'" }
    $key = ConvertFrom-ErPemRsa -Base64 $script:ErBhdKeys[$stem]

    $b = [ErArchive]::RsaDecrypt([IO.File]::ReadAllBytes($BhdPath), $key.Modulus, $key.Exponent)

    if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'BHD5') {
        throw "$stem : decrypted header is not BHD5 - the RSA key for this archive is stale (see ErArchiveLib.ps1 constants block)"
    }
    $version = [BitConverter]::ToInt32($b, 4)
    if ($version -ne 511) { throw "$stem : unexpected BHD5 version $version" }

    $bucketCount  = [BitConverter]::ToInt32($b, 16)
    $bucketOffset = [BitConverter]::ToInt32($b, 20)

    $index = @{}
    for ($i = 0; $i -lt $bucketCount; $i++) {
        $bo = $bucketOffset + $i * 8
        $n  = [BitConverter]::ToInt32($b, $bo)
        $eo = [BitConverter]::ToInt32($b, $bo + 4)
        for ($j = 0; $j -lt $n; $j++) {
            $o = $eo + $j * 40
            $e = [pscustomobject]@{
                Hash       = [BitConverter]::ToUInt64($b, $o)
                PaddedSize = [BitConverter]::ToInt32($b, $o + 8)
                Size       = [BitConverter]::ToInt32($b, $o + 12)
                Offset     = [BitConverter]::ToInt64($b, $o + 16)
                AesKey     = $null
                Ranges     = @()
            }
            $akOff = [BitConverter]::ToInt64($b, $o + 32)
            if ($akOff -ne 0) {
                $k = New-Object byte[] 16
                [Array]::Copy($b, $akOff, $k, 0, 16)
                $e.AesKey = $k
                $rc = [BitConverter]::ToInt32($b, $akOff + 16)
                $ranges = New-Object Collections.ArrayList
                for ($r = 0; $r -lt $rc; $r++) {
                    $ro = $akOff + 20 + $r * 16
                    [void]$ranges.Add([pscustomobject]@{
                        Start = [BitConverter]::ToInt64($b, $ro)
                        End   = [BitConverter]::ToInt64($b, $ro + 8)
                    })
                }
                $e.Ranges = @($ranges)
            }
            $index[$e.Hash] = $e
        }
    }
    $index
}

function Get-ErArchiveFiles {
    <#  Pulls named files out of the game's own archives.

        Takes in-game paths like '/msg/engus/item.msgbnd.dcx' and returns path -> raw
        bytes (still DCX-compressed) for the ones present. Paths absent from every
        archive are simply omitted, so a caller can ask for DLC files on an install that
        has no DLC.

        Archives are opened lazily and in order, and the scan stops as soon as everything
        asked for has been found: decrypting Data1/Data2 costs tens of seconds each and
        msg files live in Data0 and DLC.  #>
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string[]]$Paths,
        [string[]]$Archives = @('Data0', 'DLC', 'Data1', 'Data2', 'Data3')
    )

    # The hash is over the UPPERCASED path. Both cases are tried: it costs one extra
    # lookup and removes any doubt about which convention this game version uses.
    $want = @{}
    foreach ($p in $Paths) {
        foreach ($form in @($p.ToUpperInvariant(), $p)) {
            $want[[ErArchive]::PathHash($form, [uint64]$script:ErPathHashPrime)] = $p
        }
    }

    $out = @{}
    foreach ($a in $Archives) {
        if ($out.Count -ge $Paths.Count) { break }
        $bhd = Join-Path $GameDir "$a.bhd"
        $bdt = Join-Path $GameDir "$a.bdt"
        if (-not (Test-Path $bhd) -or -not (Test-Path $bdt)) { continue }

        Write-Verbose "opening $a.bhd"
        $index = Get-ErBhdIndex -BhdPath $bhd
        $hits = @($want.Keys | Where-Object { $index.ContainsKey($_) -and -not $out.ContainsKey($want[$_]) })
        if (-not $hits.Count) { continue }

        $fs = [IO.File]::OpenRead($bdt)
        try {
            foreach ($h in $hits) {
                $e = $index[$h]
                $buf = New-Object byte[] $e.PaddedSize
                [void]$fs.Seek($e.Offset, 'Begin')
                [void]$fs.Read($buf, 0, $e.PaddedSize)
                if ($e.AesKey) { $buf = Unprotect-ErArchiveEntry -Bytes $buf -Entry $e }
                # Trim the padding the archive adds to reach its alignment. Size is 0 for
                # entries the archive does not declare a true length for; the padding is
                # harmless there because every consumer reads a self-describing header.
                if ($e.Size -gt 0 -and $e.Size -lt $e.PaddedSize) {
                    $t = New-Object byte[] $e.Size
                    [Array]::Copy($buf, 0, $t, 0, $e.Size)
                    $buf = $t
                }
                $out[$want[$h]] = $buf
                Write-Verbose "  found $($want[$h]) in $a"
            }
        }
        finally { $fs.Dispose() }
    }
    $out
}

function Unprotect-ErArchiveEntry {
    <#  Some archive entries are AES-128-ECB encrypted over declared byte ranges only,
        typically just the header, so the ranges must be honoured rather than decrypting
        the whole payload.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$Entry)

    $aes = New-Object Security.Cryptography.RijndaelManaged
    $aes.KeySize = 128
    $aes.BlockSize = 128
    $aes.Key = $Entry.AesKey
    $aes.IV = New-Object byte[] 16
    $aes.Mode = [Security.Cryptography.CipherMode]::ECB
    $aes.Padding = [Security.Cryptography.PaddingMode]::None

    foreach ($r in $Entry.Ranges) {
        if ($r.Start -lt 0 -or $r.End -lt 0 -or $r.Start -eq $r.End) { continue }
        $len = [int]($r.End - $r.Start)
        if ($r.Start + $len -gt $Bytes.Length) { $len = $Bytes.Length - [int]$r.Start }
        $len = $len - ($len % 16)
        if ($len -le 0) { continue }
        $dec = $aes.CreateDecryptor()
        [void]$dec.TransformBlock($Bytes, [int]$r.Start, $len, $Bytes, [int]$r.Start)
        $dec.Dispose()
    }
    $aes.Dispose()
    $Bytes
}

# ==============================================================================
#  regulation.bin / PARAM
# ==============================================================================
# regulation.bin is AES-CBC over a DCX over a BND4 of PARAM files.
#
# ONLY ROW IDS ARE READ. A PARAM's row table is a flat array of (id, dataOffset,
# nameOffset), which needs no paramdef, and row ids alone answer the two questions this
# toolkit actually asks: does this item id exist in this game build, and how far up does
# a weapon's reinforcement ladder go (base+0 .. base+N all being rows of their own).
# Decoding row FIELDS would need a version-matched paramdef and is not attempted.

# EquipParamWeapon.reinforceTypeId: the ONE field this toolkit decodes.
#
# Elden Ring does NOT store a weapon's +1..+25 variants as rows of their own; a weapon has
# a single row, and its reinforcement ladder is reached indirectly:
#
#     EquipParamWeapon[base].reinforceTypeId = T
#     the ladder is the set of ReinforceParamWeapon rows T+0 .. T+N
#     max level = N
#
# Reading a field needs a paramdef, so the offset below was computed once, at build time,
# by walking soulsmods/Paramdex ER/Defs/EquipParamWeapon.xml (DataVersion 6) and summing
# field widths. Two traps worth recording, because both produced plausible-but-wrong
# numbers before the row size matched:
#   * bitfields pack by WIDTH, not by type name: "u8 x:1" and "dummy8 y:7" share a byte;
#   * the result must land naturally aligned, and the computed row size must equal the
#     row stride actually present in the file. Both are asserted below.
#
# IF A PATCH CHANGES THE PARAM LAYOUT the row-size assertion fires and names this block.
$script:ErWeaponRowSize        = 664
$script:ErReinforceTypeIdOffet = 218   # s16

function Get-ErRegulationFiles {
    <#  Decrypts regulation.bin and returns leafName -> byte[] for the params inside.
        AES-CBC (IV = the first 16 bytes) -> DCX -> BND4.  #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "regulation.bin not found: $Path" }

    $enc = [IO.File]::ReadAllBytes($Path)
    $iv = New-Object byte[] 16
    [Array]::Copy($enc, 0, $iv, 0, 16)

    $aes = New-Object Security.Cryptography.RijndaelManaged
    $aes.KeySize = 256
    $aes.BlockSize = 128
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::None
    $aes.Key = $script:ErRegulationKey
    $aes.IV = $iv

    $body = New-Object byte[] ($enc.Length - 16)
    [Array]::Copy($enc, 16, $body, 0, $body.Length)
    # CBC needs whole blocks; anything past the last full block is padding.
    $whole = $body.Length - ($body.Length % 16)
    $dec = $aes.CreateDecryptor()
    $plain = New-Object byte[] $whole
    [void]$dec.TransformBlock($body, 0, $whole, $plain, 0)
    $dec.Dispose(); $aes.Dispose()

    Get-ErBnd4Files -Bytes (Expand-ErDcx -Bytes $plain)
}

function Get-ErWeaponMaxLevels {
    <#  Returns baseWeaponId -> maximum reinforcement level, read from the regulation.

        This makes "cap the level at what this build allows" exact rather than a
        guess. In vanilla it separates the +25 ladder from the +10 somber one per weapon;
        against a mod's regulation it reports whatever that mod actually defines.  #>
    param([Parameter(Mandatory)][string]$Path, $Files)

    if (-not $Files) { $Files = Get-ErRegulationFiles -Path $Path }
    foreach ($needed in @('EquipParamWeapon.param', 'ReinforceParamWeapon.param')) {
        if (-not $Files.ContainsKey($needed)) { throw "regulation has no $needed" }
    }

    $wp = $Files['EquipParamWeapon.param']
    $rowCount = [BitConverter]::ToUInt16($wp, 0x0A)
    if ($rowCount -lt 2) { throw 'EquipParamWeapon has too few rows to measure a row size' }

    # Ground-truth the field offset before trusting it (see the constants above).
    $stride = [int]([BitConverter]::ToInt64($wp, 0x40 + 24 + 8) - [BitConverter]::ToInt64($wp, 0x40 + 8))
    if ($stride -ne $script:ErWeaponRowSize) {
        throw ("EquipParamWeapon row size is $stride, expected $($script:ErWeaponRowSize). " +
               'The param layout changed - re-derive $ErReinforceTypeIdOffet from Paramdex ' +
               'ER/Defs/EquipParamWeapon.xml (see the comment block in ErArchiveLib.ps1).')
    }

    # Which ReinforceParamWeapon rows exist -> how long each ladder is.
    $reinforce = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($id in (Get-ErParamRowIds -Bytes $Files['ReinforceParamWeapon.param'] -Label 'ReinforceParamWeapon')) {
        [void]$reinforce.Add($id)
    }

    $maxByType = @{}
    $out = @{}
    for ($i = 0; $i -lt $rowCount; $i++) {
        $o = 0x40 + $i * 24
        $id      = [BitConverter]::ToInt32($wp, $o)
        $dataOff = [int][BitConverter]::ToInt64($wp, $o + 8)
        $t = [int][BitConverter]::ToInt16($wp, $dataOff + $script:ErReinforceTypeIdOffet)

        if (-not $maxByType.ContainsKey($t)) {
            $n = 0
            while ($reinforce.Contains($t + $n + 1)) { $n++ }
            $maxByType[$t] = $n
        }
        $out[$id] = $maxByType[$t]
    }
    $out
}

function Get-ErRegulationParams {
    <#  Returns paramName -> sorted int[] of row ids.  #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Only,
        $Files
    )
    if (-not (Test-Path $Path)) { throw "regulation.bin not found: $Path" }

    if (-not $Files) { $Files = Get-ErRegulationFiles -Path $Path }

    $out = @{}
    foreach ($leaf in $Files.Keys) {
        if ($leaf -notlike '*.param') { continue }
        $name = [IO.Path]::GetFileNameWithoutExtension($leaf)
        if ($Only -and $name -notin $Only) { continue }
        $out[$name] = Get-ErParamRowIds -Bytes $Files[$leaf] -Label $name
    }
    $out
}

function Get-ErParamRowIds {
    <#  Row ids only, no paramdef needed.

        PARAM header (64-bit variants, which is all Elden Ring uses):
          0x00 u32 stringsOffset   0x04 u16 shortDataOffset   0x06 u16 unk06
          0x08 u16 paramdefDataVersion   0x0A u16 rowCount
        Rows follow the header at 0x40, 24 bytes each:
          i32 id, i32 pad, i64 dataOffset, i64 nameOffset

        rowCount is a u16, so a param with more than 65,535 rows would wrap; none in
        Elden Ring do, and the ids are sanity-checked below regardless.  #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [string]$Label = 'param')

    $rowCount = [BitConverter]::ToUInt16($Bytes, 0x0A)
    $ids = New-Object Collections.Generic.List[int]
    for ($i = 0; $i -lt $rowCount; $i++) {
        $o = 0x40 + $i * 24
        if ($o + 24 -gt $Bytes.Length) { break }
        $id = [BitConverter]::ToInt32($Bytes, $o)
        $dataOff = [BitConverter]::ToInt64($Bytes, $o + 8)
        # A misread stride shows up immediately as absurd ids or offsets outside the file.
        if ($id -lt 0 -or $dataOff -le 0 -or $dataOff -ge $Bytes.Length) {
            throw "$Label : row $i looks wrong (id $id, dataOffset $dataOff) - PARAM layout may have changed"
        }
        $ids.Add($id)
    }
    , ($ids.ToArray() | Sort-Object)
}
