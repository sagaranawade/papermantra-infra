# =============================================================================
# Sync local MongoDB + question images to production VPS.
#
# Prerequisites:
#   - Docker Desktop (for mongodump via mongo:7.0 image)
#   - OpenSSH client (scp/ssh)
#   - Local MongoDB on port 27017 with papermantra + pdfgenerator databases
#   - scripts/sync-data.config (copy from sync-data.config.example)
#
# Usage (PowerShell, from papermantra-infra):
#   .\scripts\sync-data-to-prod.ps1
#   .\scripts\sync-data-to-prod.ps1 -SkipMongo
#   .\scripts\sync-data-to-prod.ps1 -SkipImages
# =============================================================================
param(
    [switch]$SkipMongo,
    [switch]$SkipImages
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraRoot = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $ScriptDir 'sync-data.config'

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Missing $ConfigFile — copy scripts/sync-data.config.example to scripts/sync-data.config"
}

$config = @{}
Get-Content $ConfigFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
        $config[$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

$VpsHost = $config['VPS_HOST']
$VpsUser = $config['VPS_USER']
$VpsPath = $config['VPS_PATH']
$SshKey = $config['SSH_KEY']
$MongoHost = $config['LOCAL_MONGO_HOST']
$MongoPort = $config['LOCAL_MONGO_PORT']
$ServicesRoot = $config['PAPERMANTRA_SERVICES_ROOT']
$PdfRoot = $config['PDFGENERATOR_ROOT']
$PmDb = $config['PAPERMANTRA_DB']
$PdfDb = $config['PDFGENERATOR_DB']

$SshArgs = @('-o', 'BatchMode=yes', '-i', $SshKey)
$Remote = "${VpsUser}@${VpsHost}"
$StagingLocal = Join-Path $env:TEMP "papermantra-sync-$(Get-Date -Format 'yyyyMMddHHmmss')"
$StagingRemote = "${VpsPath}/.sync-staging"

New-Item -ItemType Directory -Force -Path $StagingLocal | Out-Null
Write-Host ">> Local staging: $StagingLocal"

function Invoke-DockerMongo {
    param([string[]]$MongoArgs)
    docker run --rm `
        --add-host=host.docker.internal:host-gateway `
        -v "${StagingLocal}:/backup" `
        mongo:7.0 `
        @MongoArgs
}

if (-not $SkipMongo) {
    Write-Host ">> Dumping MongoDB: $PmDb"
    Invoke-DockerMongo @(
        'mongodump',
        "--host=${MongoHost}",
        "--port=${MongoPort}",
        "--db=${PmDb}",
        '--archive=/backup/papermantra.archive.gz',
        '--gzip'
    )

    Write-Host ">> Dumping MongoDB: $PdfDb"
    Invoke-DockerMongo @(
        'mongodump',
        "--host=${MongoHost}",
        "--port=${MongoPort}",
        "--db=${PdfDb}",
        '--archive=/backup/pdfgenerator.archive.gz',
        '--gzip'
    )
}

if (-not $SkipImages) {
    $apiImages = Join-Path $ServicesRoot 'images'
    $apiUserPic = Join-Path $ServicesRoot 'userPic'
    $pdfImages = Join-Path $PdfRoot 'images'

    foreach ($pair in @(
        @{ Name = 'api-images'; Path = $apiImages },
        @{ Name = 'api-userPic'; Path = $apiUserPic },
        @{ Name = 'pdf-images'; Path = $pdfImages }
    )) {
        if (-not (Test-Path $pair.Path)) {
            Write-Warning "Missing $($pair.Path) — skipping $($pair.Name)"
            continue
        }
        $dest = Join-Path $StagingLocal $pair.Name
        Write-Host ">> Copying $($pair.Name) from $($pair.Path)"
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        robocopy $pair.Path $dest /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $($pair.Name) with exit $LASTEXITCODE" }
    }
}

Write-Host ">> Uploading to ${Remote}:${StagingRemote} ..."
ssh @SshArgs $Remote "mkdir -p '${StagingRemote}'"
scp @SshArgs -r "${StagingLocal}\*" "${Remote}:${StagingRemote}/"

Write-Host ">> Running restore on VPS..."
$restoreFlags = @()
if ($SkipMongo) { $restoreFlags += '--skip-mongo' }
if ($SkipImages) { $restoreFlags += '--skip-images' }
$flagStr = ($restoreFlags -join ' ')
ssh @SshArgs $Remote "cd '${VpsPath}' && git pull origin main && chmod +x scripts/restore-data-on-vps.sh && ./scripts/restore-data-on-vps.sh ${flagStr}"

Write-Host ">> Sync complete."
Write-Host "   Staging left at: $StagingLocal (delete manually when done)"
