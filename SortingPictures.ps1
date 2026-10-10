# Jeśli PowerShell wyświetli błąd „running scripts is disabled on this system”,
# uruchom skrypt w tej sesji poleceniem:
# powershell.exe -ExecutionPolicy Bypass -File .\SortingPictures.ps1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)]
    [string]$PhotoRoot
)

$scriptVersion = '1.0.6'
Write-Host "SortingPictures.ps1 v$scriptVersion"

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PhotoRoot)) {
    $defaultRoot = 'Z:\miasik_jakub\Zdjecia'
    $enteredRoot = Read-Host "Podaj folder glowny zdjec [$defaultRoot] (Enter = domyslny)"
    if ([string]::IsNullOrWhiteSpace($enteredRoot)) {
        $PhotoRoot = $defaultRoot
    }
    else {
        $PhotoRoot = $enteredRoot.Trim()
    }
}

if (-not (Test-Path -LiteralPath $PhotoRoot -PathType Container)) {
    throw "Folder glowny nie istnieje lub jest niedostepny: $PhotoRoot"
}

$scriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = $MyInvocation.MyCommand.Path
$files = @(
    Get-ChildItem -LiteralPath $scriptFolder -File |
        Where-Object { $_.FullName -ne $scriptPath } |
        Sort-Object Name
)
$limitInput = Read-Host 'Ile pierwszych plikow przeniesc? Enter = wszystkie'

if (-not [string]::IsNullOrWhiteSpace($limitInput)) {
    $limit = 0
    if (-not [int]::TryParse($limitInput.Trim(), [ref]$limit) -or $limit -lt 1) {
        throw 'Podaj dodatnia liczbe calkowita albo nacisnij Enter, aby wybrac wszystkie pliki.'
    }

    $files = @($files | Select-Object -First $limit)
}

Write-Host "Plikow wybranych do sprawdzenia: $($files.Count)"
$datePattern = '^(?:Film )?(?<date>\d{4}-\d{2}-\d{2})_(?<time>\d{2}-\d{2}-\d{2})(?:_\d+)?\..+$'
$dateFormat = 'yyyy-MM-dd_HH-mm-ss'
$culture = [Globalization.CultureInfo]::InvariantCulture
$moved = 0
$skipped = 0
$errors = 0

foreach ($file in $files) {
    if ($file.Name -notmatch $datePattern) {
        Write-Warning "Pominieto plik o nieobslugiwanej nazwie: $($file.Name)"
        $skipped++
        continue
    }

    $dateText = '{0}_{1}' -f $Matches.date, $Matches.time
    $parsedDate = [datetime]::MinValue
    $validDate = [datetime]::TryParseExact($dateText, $dateFormat, $culture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)
    if (-not $validDate) {
        Write-Warning "Pominieto plik z nieprawidlowa data lub godzina: $($file.Name)"
        $skipped++
        continue
    }

    $yearFolder = Join-Path $PhotoRoot ($parsedDate.ToString('yyyy'))
    $destinationFolder = Join-Path $yearFolder ($parsedDate.ToString('MM'))
    $destinationFile = Join-Path $destinationFolder $file.Name

    if (Test-Path -LiteralPath $destinationFile) {
        Write-Warning "Konflikt - plik docelowy juz istnieje, pozostawiono bez zmian: $destinationFile"
        $skipped++
        continue
    }

    if ($PSCmdlet.ShouldProcess($destinationFile, "Przenies plik z $($file.FullName)")) {
        if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        }

        # Ponownie sprawdzamy cel przed przeniesieniem, aby nie nadpisac pliku,
        # ktory mogl pojawic sie po wczesniejszej kontroli.
        if (Test-Path -LiteralPath $destinationFile) {
            Write-Warning "Konflikt - plik docelowy pojawil sie w trakcie pracy, pozostawiono bez zmian: $destinationFile"
            $skipped++
            continue
        }

        $moveErrors = @()
        Move-Item -LiteralPath $file.FullName -Destination $destinationFile -ErrorAction SilentlyContinue -ErrorVariable moveErrors
        if ($moveErrors.Count -gt 0) {
            Write-Warning "Nie udalo sie przeniesc '$($file.Name)': $($moveErrors[0].Exception.Message)"
            $errors++
        }
        else {
            Write-Host "Przeniesiono: $($file.Name) -> $destinationFolder"
            $moved++
        }
    }
}

Write-Host "`nPodsumowanie: przeniesiono $moved, pominieto $skipped, bledy $errors."
