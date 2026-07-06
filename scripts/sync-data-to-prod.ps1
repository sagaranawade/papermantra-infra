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

Write-Host ">> Uploading to ${Remote}:${StagingRemote} ..."
ssh @SshArgs $Remote "mkdir -p '${StagingRemote}'"
scp @SshArgs "${StagingLocal}\papermantra.archive.gz" "${StagingLocal}\pdfgenerator.archive.gz" "${Remote}:${StagingRemote}/"

Write-Host ">> Running restore on VPS..."
ssh @SshArgs $Remote "cd '${VpsPath}' && git pull origin main && chmod +x scripts/restore-data-on-vps.sh && ./scripts/restore-data-on-vps.sh"

Write-Host ">> Sync complete."
Write-Host "   Staging left at: $StagingLocal (delete manually when done)"
