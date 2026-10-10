# Jeśli PowerShell wyświetli błąd „running scripts is disabled on this system”,
# uruchom skrypt w tej sesji poleceniem:
# powershell.exe -ExecutionPolicy Bypass -File .\MoveFolderAbove.ps1

$scriptVersion = '1.0.0'
Write-Host "MoveFolderAbove.ps1 v$scriptVersion"

$destination = (Get-Location).Path

$sourceFiles = @(Get-ChildItem -LiteralPath $destination -Directory | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -File -Recurse
})
$totalFiles = $sourceFiles.Count
$processedFiles = 0

foreach ($sourceFile in $sourceFiles) {
    $targetPath = Join-Path $destination $sourceFile.Name

    $counter = 1
    while (Test-Path -LiteralPath $targetPath) {
        $newName = '{0}_{1}{2}' -f $sourceFile.BaseName, $counter, $sourceFile.Extension
        $targetPath = Join-Path $destination $newName
        $counter++
    }

    Move-Item -LiteralPath $sourceFile.FullName -Destination $targetPath
    $processedFiles++
    $percentComplete = [int](($processedFiles / $totalFiles) * 100)
    Write-Progress -Activity 'Przenoszenie plików do folderu nadrzędnego' `
        -Status ("{0}/{1}: {2}" -f $processedFiles, $totalFiles, $sourceFile.Name) `
        -PercentComplete $percentComplete
}

if ($totalFiles -gt 0) {
    Write-Progress -Activity 'Przenoszenie plików do folderu nadrzędnego' -Completed
    Write-Host ("Przeniesiono plikow: {0}." -f $processedFiles)
} else {
    Write-Host 'Nie znaleziono plikow do przeniesienia.'
}
