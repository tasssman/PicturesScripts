# Jeśli PowerShell wyświetli błąd „running scripts is disabled on this system”,
# uruchom skrypt w tej sesji poleceniem:
# powershell.exe -ExecutionPolicy Bypass -File .\RenamePicture.ps1

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string] $Path = (Get-Location).Path,

    [switch] $Recurse
)

$scriptVersion = '1.0.0'
Write-Host "RenamePicture.ps1 v$scriptVersion"

# Uses the EXIF DateTimeOriginal tag (0x9003), falling back to DateTimeDigitized
# (0x9004) and then the general DateTime tag (0x0132).
Add-Type -AssemblyName System.Drawing
Write-Output 'RenamePicture.ps1: EXIF JPEG parser v8'

function ConvertFrom-ExifDateString {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $cleanValue = [regex]::Replace($Value, '[^0-9:.\- ]', '').Trim()
    $dateMatch = [regex]::Match($cleanValue, '^(\d{4})[:\-](\d{1,2})[:\-](\d{1,2})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.\d+)?$')
    if (-not $dateMatch.Success) { return $null }

    try {
        return [datetime]::new(
            [int]$dateMatch.Groups[1].Value, [int]$dateMatch.Groups[2].Value, [int]$dateMatch.Groups[3].Value,
            [int]$dateMatch.Groups[4].Value, [int]$dateMatch.Groups[5].Value, [int]$dateMatch.Groups[6].Value
        )
    } catch {
        return $null
    }
}

$imageExtensions = @('.jpg', '.jpeg', '.tif', '.tiff')
$getCaptureDate = {
    param([string] $FilePath)

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($FilePath)
        $propertyItems = @($image.PropertyItems)
        Write-Verbose ('EXIF tag IDs in {0}: {1}' -f [System.IO.Path]::GetFileName($FilePath), (($propertyItems | ForEach-Object { '0x{0:X4}' -f [int]$_.Id }) -join ', '))
        foreach ($tag in @(0x9003, 0x9004, 0x0132)) {
            $item = $propertyItems | Where-Object { [int]$_.Id -eq $tag } | Select-Object -First 1
            if ($null -ne $item) {
                $value = [System.Text.Encoding]::ASCII.GetString($item.Value)
                Write-Verbose ('EXIF 0x{0:X4}: Type={1}; Raw=<{2}>' -f $tag, $item.Type, $value)
                $parsed = ConvertFrom-ExifDateString -Value $value
                if ($null -ne $parsed) { return $parsed }
            }
        }
    } catch {
        Write-Warning ("Nie mo{0}na odczyta{1} metadanych: {2} ({3})" -f [char]0x017C, [char]0x0107, $FilePath, $_.Exception.Message)
    } finally {
        if ($null -ne $image) { $image.Dispose() }
    }

    # Windows Shell exposes the same capture-time metadata for formats/codecs
    # that System.Drawing cannot read.
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -LiteralPath $FilePath -Parent))
        $shellFile = $folder.ParseName((Split-Path -LiteralPath $FilePath -Leaf))
        $shellDate = $shellFile.ExtendedProperty('System.Photo.DateTaken')
        if ($shellDate -is [datetime]) { return $shellDate }
        if ($shellDate) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse([string]$shellDate, [Globalization.CultureInfo]::CurrentCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
                return $parsed
            }
        }
    } catch {
        # No Windows Shell date was available; report the missing date below.
    }
    return $null
}

function Get-JpegExifCaptureDate {
    param([Parameter(Mandatory)][string] $FilePath)

    # Read EXIF date tags directly from the JPEG APP1/TIFF structure. This is
    # still metadata-only and avoids depending on installed image codecs.
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8) { return $null }

    $position = 2
    while ($position + 4 -le $bytes.Length) {
        while ($position -lt $bytes.Length -and $bytes[$position] -ne 0xFF) { $position++ }
        while ($position -lt $bytes.Length -and $bytes[$position] -eq 0xFF) { $position++ }
        if ($position -ge $bytes.Length) { break }

        $marker = [int]$bytes[$position]
        $position++
        if ($marker -eq 0xD9 -or $marker -eq 0xDA) { break }
        if ($marker -eq 0xD8 -or $marker -eq 0x01 -or ($marker -ge 0xD0 -and $marker -le 0xD7)) { continue }
        if ($position + 2 -gt $bytes.Length) { break }

        $segmentLength = ([int]$bytes[$position] * 256) + [int]$bytes[$position + 1]
        if ($segmentLength -lt 2 -or $position + $segmentLength -gt $bytes.Length) { break }
        $payload = $position + 2

        if ($marker -eq 0xE1 -and $segmentLength -ge 14 -and
            [System.Text.Encoding]::ASCII.GetString($bytes, $payload, 6) -eq "Exif`0`0") {
            $tiff = $payload + 6
            $littleEndian = $bytes[$tiff] -eq 0x49 -and $bytes[$tiff + 1] -eq 0x49
            $bigEndian = $bytes[$tiff] -eq 0x4D -and $bytes[$tiff + 1] -eq 0x4D
            if (-not ($littleEndian -or $bigEndian)) { return $null }

            $readU16 = {
                param([int]$At)
                if ($littleEndian) { return ([int]$bytes[$At] + ([int]$bytes[$At + 1] * 256)) }
                return (([int]$bytes[$At] * 256) + [int]$bytes[$At + 1])
            }
            $readU32 = {
                param([int]$At)
                if ($littleEndian) {
                    return ([uint64]$bytes[$At] + ([uint64]$bytes[$At + 1] * 256) + ([uint64]$bytes[$At + 2] * 65536) + ([uint64]$bytes[$At + 3] * 16777216))
                }
                return (([uint64]$bytes[$At] * 16777216) + ([uint64]$bytes[$At + 1] * 65536) + ([uint64]$bytes[$At + 2] * 256) + [uint64]$bytes[$At + 3])
            }

            if ((& $readU16 ($tiff + 2)) -ne 42) { return $null }
            $ifd0 = $tiff + [int](& $readU32 ($tiff + 4))
            $ifd0Date = $null
            $exifIfdOffset = 0

            $readIfd = {
                param([int]$IfdAt)
                $result = @{ Date = $null; ExifOffset = 0 }
                if ($IfdAt -lt $tiff -or $IfdAt + 2 -gt $bytes.Length) { return $result }
                $entryCount = & $readU16 $IfdAt
                for ($entry = 0; $entry -lt $entryCount; $entry++) {
                    $entryAt = $IfdAt + 2 + ($entry * 12)
                    if ($entryAt + 12 -gt $bytes.Length) { break }
                    $tag = & $readU16 $entryAt
                    $type = & $readU16 ($entryAt + 2)
                    $valueCount = & $readU32 ($entryAt + 4)
                    if ($tag -eq 0x8769 -and $type -eq 4) {
                        $result.ExifOffset = [int](& $readU32 ($entryAt + 8))
                    }
                    if (($tag -eq 0x0132 -or $tag -eq 0x9003 -or $tag -eq 0x9004) -and $type -eq 2 -and $valueCount -gt 0 -and $valueCount -le 64) {
                        if ($valueCount -le 4) { $valueAt = $entryAt + 8 }
                        else { $valueAt = $tiff + [int](& $readU32 ($entryAt + 8)) }
                        if ($valueAt -ge $tiff -and $valueAt + $valueCount -le $bytes.Length) {
                            $result.Date = [System.Text.Encoding]::ASCII.GetString($bytes, $valueAt, [int]$valueCount).Trim([char]0, ' ')
                            if ($tag -eq 0x9003) { return $result }
                        }
                    }
                }
                return $result
            }

            $mainIfd = & $readIfd $ifd0
            $ifd0Date = $mainIfd.Date
            $exifIfdOffset = $mainIfd.ExifOffset
            $dateValues = @()
            if ($exifIfdOffset -gt 0) {
                $exifIfd = & $readIfd ($tiff + $exifIfdOffset)
                if ($exifIfd.Date) { $dateValues += $exifIfd.Date }
            }
            if ($ifd0Date) { $dateValues += $ifd0Date }

            foreach ($dateValue in $dateValues) {
                $parsed = ConvertFrom-ExifDateString -Value ([string]$dateValue)
                if ($null -ne $parsed) { return $parsed }
            }
            return $null
        }
        $position += $segmentLength
    }
    return $null
}

$items = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse |
    Where-Object { $imageExtensions -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object FullName

$renamePlan = [System.Collections.Generic.List[object]]::new()
$plannedDestinations = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$itemIndex = 0
foreach ($file in $items) {
    $itemIndex++
    $progressText = '[{0}/{1}] Odczyt EXIF: {2}' -f $itemIndex, $items.Count, $file.Name

    if ($file.BaseName -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(?:_\d{2,})?$') {
        Write-Host "$progressText | Pomijam: nazwa jest juz w wymaganym formacie."
        continue
    }

    $captureDate = & $getCaptureDate $file.FullName
    if ($null -eq $captureDate) {
        try {
            $captureDate = Get-JpegExifCaptureDate -FilePath $file.FullName
        } catch {
            Write-Warning "Blad bezposredniego odczytu EXIF dla $($file.Name): $($_.Exception.Message)"
        }
    }
    if ($null -eq $captureDate) {
        Write-Warning "Brak poprawnej daty EXIF, pomijam: $($file.Name)"
        continue
    }

    $baseName = $captureDate.ToString('yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
    $extension = $file.Extension.ToLowerInvariant()
    $destination = Join-Path $file.DirectoryName ($baseName + $extension)
    $suffix = 1
    while (((Test-Path -LiteralPath $destination) -or $plannedDestinations.Contains([System.IO.Path]::GetFullPath($destination))) -and
           ([System.IO.Path]::GetFullPath($destination) -ne [System.IO.Path]::GetFullPath($file.FullName))) {
        $destination = Join-Path $file.DirectoryName ('{0}_{1:D2}{2}' -f $baseName, $suffix, $extension)
        $suffix++
    }

    if ([System.IO.Path]::GetFullPath($destination) -eq [System.IO.Path]::GetFullPath($file.FullName)) {
        continue
    }

    $newName = [System.IO.Path]::GetFileName($destination)
    if ([System.IO.Path]::GetFullPath($destination) -eq [System.IO.Path]::GetFullPath($file.FullName)) {
        continue
    }
    [void]$plannedDestinations.Add([System.IO.Path]::GetFullPath($destination))
    $renamePlan.Add([pscustomobject]@{ Source = $file; Destination = $destination; NewName = $newName })
    Write-Host ("{0} | Zmiana na: {1}" -f $progressText, $newName)
}

if ($renamePlan.Count -eq 0) {
    Write-Output ('Brak plik{0}w do zmiany.' -f [char]0x00F3)
    return
}

if (-not $WhatIfPreference) {
    $answer = Read-Host ('Wykona{0} powy{1}sze zmiany? (T/N)' -f [char]0x0107, [char]0x017C)
    if ($answer -notmatch '^(T|TAK|Y|YES)$') {
        Write-Output ('Anulowano. {0}aden plik nie zosta{1} zmieniony.' -f [char]0x017B, [char]0x0142)
        return
    }
}

foreach ($plan in $renamePlan) {
    if ($PSCmdlet.ShouldProcess($plan.Source.FullName, "Rename to $($plan.NewName)")) {
        Rename-Item -LiteralPath $plan.Source.FullName -NewName $plan.NewName
    }
}
