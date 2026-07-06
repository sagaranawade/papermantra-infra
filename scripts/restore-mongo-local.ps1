# =============================================================================
# Restore LOCAL MongoDB from a papermantra-sync staging folder (Windows).
# Use when local data was lost but a good dump still exists under %TEMP%.
#
# Usage:
#   .\scripts\restore-mongo-local.ps1
#   .\scripts\restore-mongo-local.ps1 -StagingDir "C:\Users\Sagar\AppData\Local\Temp\papermantra-sync-20260706234209"
# =============================================================================
param(
    [string]$StagingDir = "C:\Users\Sagar\AppData\Local\Temp\papermantra-sync-20260706234209",
    [string]$MongoHost = "host.docker.internal",
    [int]$MongoPort = 27017,
    [int]$MinBytes = 1024
)

$ErrorActionPreference = 'Stop'

$pm = Join-Path $StagingDir 'papermantra.archive.gz'
$pdf = Join-Path $StagingDir 'pdfgenerator.archive.gz'

foreach ($f in @($pm, $pdf)) {
    if (-not (Test-Path $f)) { Write-Error "Missing: $f" }
    $sz = (Get-Item $f).Length
    if ($sz -lt $MinBytes) { Write-Error "Archive too small ($sz bytes): $f" }
    Write-Host "OK: $f ($sz bytes)"
}

Write-Host ">> Restoring papermantra to ${MongoHost}:${MongoPort} ..."
docker run --rm --add-host=host.docker.internal:host-gateway -v "${StagingDir}:/backup" mongo:7.0 `
    mongorestore --host=$MongoHost --port=$MongoPort --archive=/backup/papermantra.archive.gz --gzip --drop --nsInclude=papermantra.*

Write-Host ">> Restoring pdfgenerator ..."
docker run --rm --add-host=host.docker.internal:host-gateway -v "${StagingDir}:/backup" mongo:7.0 `
    mongorestore --host=$MongoHost --port=$MongoPort --archive=/backup/pdfgenerator.archive.gz --gzip --drop --nsInclude=pdfgenerator.*

Write-Host ">> Local MongoDB restore complete. Check Compass: localhost:27017"
