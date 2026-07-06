# =============================================================================
# Sync local MongoDB databases to production VPS.
#
# Prerequisites:
#   - Docker Desktop (for mongodump via mongo:7.0 image)
#   - OpenSSH client (scp/ssh)
#   - Local MongoDB on port 27017 with papermantra + pdfgenerator databases
#   - scripts/sync-data.config (copy from sync-data.config.example)
#
# Usage (PowerShell, from papermantra-infra):
#   .\scripts\sync-data-to-prod.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir 'sync-data.config'

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Missing $ConfigFile - copy scripts/sync-data.config.example to scripts/sync-data.config"
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

$pmArchive = Join-Path $StagingLocal 'papermantra.archive.gz'
$pdfArchive = Join-Path $StagingLocal 'pdfgenerator.archive.gz'
$minBytes = 500

foreach ($pair in @(
    @{ Label = $PmDb; Path = $pmArchive },
    @{ Label = $PdfDb; Path = $pdfArchive }
)) {
    if (-not (Test-Path $pair.Path)) {
        Write-Error "Dump missing: $($pair.Path)"
    }
    $size = (Get-Item $pair.Path).Length
    if ($size -lt $minBytes) {
        Write-Error @"
$($pair.Label) dump is only ${size} bytes — local MongoDB appears empty.

Your Mongo on ${MongoHost}:${MongoPort} has no data to sync. Before re-running:
  1. Start the stack that has your dev data (papermantraservices or pdfgenerator docker compose)
  2. Or dump from MongoDB Atlas / another backup (see scripts/sync-data.config.example)
  3. Verify counts:
     docker run --rm --add-host=host.docker.internal:host-gateway mongo:7.0 mongosh --quiet mongodb://${MongoHost}:${MongoPort}/${PmDb} --eval "db.login_info.countDocuments()"
"@
    }
    Write-Host "   $($pair.Label) archive: $size bytes"
}

Write-Host ">> Uploading to ${Remote}:${StagingRemote} ..."
ssh @SshArgs $Remote "mkdir -p '${StagingRemote}'"
scp @SshArgs "${StagingLocal}\papermantra.archive.gz" "${StagingLocal}\pdfgenerator.archive.gz" "${Remote}:${StagingRemote}/"

Write-Host ">> Running restore on VPS..."
ssh @SshArgs $Remote "cd '${VpsPath}' && git pull origin main && chmod +x scripts/restore-data-on-vps.sh && ./scripts/restore-data-on-vps.sh"

Write-Host ">> Sync complete."
Write-Host "   Staging left at: $StagingLocal (delete manually when done)"
Write-Host ""
Write-Host "NOTE: MongoDB sync does NOT copy branding image files."
Write-Host "      Run: .\scripts\branding-sync.ps1 -Deploy"
Write-Host "      to sync papermantraservices\user-uploads to production."
