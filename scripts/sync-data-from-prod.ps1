# =============================================================================
# Pull production MongoDB -> local MongoDB (complete automation).
#
# Dumps papermantra + pdfgenerator on the VPS (inside papermantra-mongodb),
# downloads gzip archives over SCP, then restores into your local mongod.
#
# Prerequisites:
#   - OpenSSH client (ssh / scp)
#   - scripts/sync-data.config (copy from sync-data.config.example)
#   - Local MongoDB running on LOCAL_MONGO_PORT (default 27017)
#   - MongoDB Database Tools (mongodump/mongorestore) OR Docker Desktop
#
# Usage (PowerShell, from papermantra-infra):
#   .\scripts\sync-data-from-prod.ps1
#   .\scripts\sync-data-from-prod.ps1 -DumpOnly
#   .\scripts\sync-data-from-prod.ps1 -RestoreOnly -StagingDir "D:\...\backups\from-prod-20260807T103000Z"
#   .\scripts\sync-data-from-prod.ps1 -SkipDrop
#
# Schedule (Task Scheduler, daily):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "...\scripts\sync-data-from-prod.ps1"
# =============================================================================
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $StagingDir = "",
    [string] $LocalMongoHost = "",
    [int] $LocalMongoPort = 0,
    [switch] $DumpOnly,
    [switch] $RestoreOnly,
    [switch] $SkipDrop,
    [switch] $KeepRemoteStaging,
    [int] $MinBytes = 1024
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir "sync-data.config"
}

function Read-Config([string] $path) {
    if (-not (Test-Path $path)) {
        throw "Config not found: $path`nCopy scripts/sync-data.config.example to scripts/sync-data.config"
    }
    $map = @{}
    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $val = $line.Substring($idx + 1).Trim()
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $map[$line.Substring(0, $idx).Trim()] = $val
    }
    return $map
}

function Resolve-MongoTool([string] $name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "C:\Program Files\MongoDB\Tools\100\bin\$name.exe",
        "C:\Program Files\MongoDB\Tools\100\bin\$name",
        "C:\Program Files\MongoDB\Server\8.0\bin\$name.exe",
        "C:\Program Files\MongoDB\Server\7.0\bin\$name.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Test-TcpPort([string] $hostName, [int] $port, [int] $timeoutSec = 5) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($timeoutSec), $false)
        if (-not $ok) { $client.Close(); return $false }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Normalize-LocalMongoHost([string] $hostName, [bool] $nativeTools) {
    if (-not $hostName) { return "127.0.0.1" }
    if ($nativeTools -and ($hostName -eq "host.docker.internal" -or $hostName -eq "localhost")) {
        return "127.0.0.1"
    }
    return $hostName
}

$config = Read-Config $ConfigPath
$vpsHost = $config["VPS_HOST"]
$vpsUser = if ($config["VPS_USER"]) { $config["VPS_USER"] } else { "deploy" }
$vpsPath = if ($config["VPS_PATH"]) { $config["VPS_PATH"] } else { "/opt/papermantra-infra" }
$sshKey = $config["SSH_KEY"]
$pmDb = if ($config["PAPERMANTRA_DB"]) { $config["PAPERMANTRA_DB"] } else { "papermantra" }
$pdfDb = if ($config["PDFGENERATOR_DB"]) { $config["PDFGENERATOR_DB"] } else { "pdfgenerator" }

if (-not $LocalMongoHost) {
    $LocalMongoHost = if ($config["LOCAL_MONGO_HOST"]) { $config["LOCAL_MONGO_HOST"] } else { "127.0.0.1" }
}
if ($LocalMongoPort -le 0) {
    $LocalMongoPort = if ($config["LOCAL_MONGO_PORT"]) { [int]$config["LOCAL_MONGO_PORT"] } else { 27017 }
}

if (-not $vpsHost) { throw "VPS_HOST missing in $ConfigPath" }
if (-not $RestoreOnly) {
    if (-not $sshKey -or -not (Test-Path $sshKey)) {
        throw "SSH_KEY missing or not found: $sshKey"
    }
}

$remote = "${vpsUser}@${vpsHost}"
$sshArgs = @("-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=15", "-i", $sshKey)
$remoteStaging = "${vpsPath}/.sync-staging/from-prod"
$archives = @(
    @{ Label = $pmDb; File = "papermantra.archive.gz"; Db = $pmDb },
    @{ Label = $pdfDb; File = "pdfgenerator.archive.gz"; Db = $pdfDb }
)

if (-not $StagingDir) {
    $stamp = Get-Date -Format "yyyyMMdd'T'HHmmss'Z'"
    $StagingDir = Join-Path $RootDir "backups\from-prod-$stamp"
}

New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null
Write-Host ">> Staging: $StagingDir" -ForegroundColor Cyan

# --- Dump on VPS + download -------------------------------------------------
if (-not $RestoreOnly) {
    Write-Host ">> Preflight SSH ${remote} ..." -ForegroundColor Cyan
    if (-not (Test-TcpPort $vpsHost 22 10)) {
        throw "Cannot reach ${vpsHost}:22 - open firewall / VPN, then retry."
    }

    # Upload + run a remote bash script (reliable exit codes on Windows OpenSSH).
    # IMPORTANT: must be LF-only; CRLF makes bash fail with: set: pipefail: invalid option name
    $remoteScriptName = "dump-from-prod-remote.sh"
    $localRemoteScript = Join-Path $env:TEMP $remoteScriptName
    $remoteScriptOnVps = "$remoteStaging/$remoteScriptName"

    $remoteLines = @(
        'set -euo pipefail'
        "cd '$vpsPath'"
        'set -a'
        'source .env'
        'set +a'
        "mkdir -p '$remoteStaging'"
        'dump_one() {'
        '  db="$1"'
        '  out="$2"'
        '  echo ">> mongodump db=$db -> $out"'
        '  rm -f "$out"'
        '  docker compose exec -T mongodb mongodump --username="$MONGO_ROOT_USER" --password="$MONGO_ROOT_PASSWORD" --authenticationDatabase=admin --db="$db" --archive --gzip --numParallelCollections=4 > "$out"'
        '  if [[ ! -s "$out" ]]; then'
        '    echo "ERROR: dump archive missing or empty: $out" >&2'
        '    exit 1'
        '  fi'
        '  ls -lh "$out"'
        '}'
        'PM_DB="${MONGODB_DATABASE:-papermantra}"'
        'PDF_DB="${PDF_MONGODB_DATABASE:-pdfgenerator}"'
        "dump_one `"`$PM_DB`" '$remoteStaging/papermantra.archive.gz'"
        "dump_one `"`$PDF_DB`" '$remoteStaging/pdfgenerator.archive.gz'"
        'echo ">> Remote dumps OK"'
        "ls -lh '$remoteStaging'"
    )
    # Join with LF only (never CRLF) so Linux bash accepts the script.
    $remoteScript = ($remoteLines -join "`n") + "`n"

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($localRemoteScript, $remoteScript, $utf8NoBom)

    Write-Host ">> Preparing remote staging ..." -ForegroundColor Cyan
    ssh @sshArgs $remote "mkdir -p '$remoteStaging'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create remote staging dir" }

    Write-Host ">> Uploading dump script ..." -ForegroundColor Cyan
    scp @sshArgs $localRemoteScript "${remote}:${remoteScriptOnVps}"
    if ($LASTEXITCODE -ne 0) { throw "Failed to upload remote dump script" }

    Write-Host ">> Dumping on VPS (mongodump inside papermantra-mongodb) ..." -ForegroundColor Cyan
    ssh @sshArgs $remote "sed -i 's/\r$//' '$remoteScriptOnVps' && bash '$remoteScriptOnVps'"
    if ($LASTEXITCODE -ne 0) {
        throw "Remote mongodump failed (exit $LASTEXITCODE). Check VPS docker/mongodb logs."
    }

    Write-Host ">> Verifying remote archives ..." -ForegroundColor Cyan
    foreach ($a in $archives) {
        $check = ssh @sshArgs $remote "stat -c%s '$remoteStaging/$($a.File)' 2>/dev/null || echo 0"
        $remoteBytes = 0
        [void][int]::TryParse(("$check").Trim(), [ref]$remoteBytes)
        if ($remoteBytes -lt $MinBytes) {
            throw "Remote archive missing/too small for $($a.Label): $remoteBytes bytes ($remoteStaging/$($a.File))"
        }
        Write-Host ("   remote {0}: {1:N0} bytes" -f $a.Label, $remoteBytes) -ForegroundColor Green
    }

    Write-Host ">> Downloading archives via SCP ..." -ForegroundColor Cyan
    foreach ($a in $archives) {
        $remoteFile = "${remote}:${remoteStaging}/$($a.File)"
        $localFile = Join-Path $StagingDir $a.File
        scp @sshArgs $remoteFile $localFile
        if ($LASTEXITCODE -ne 0) {
            throw "SCP failed for $($a.File)"
        }
    }

    if (-not $KeepRemoteStaging) {
        Write-Host ">> Cleaning remote staging ..." -ForegroundColor DarkYellow
        ssh @sshArgs $remote "rm -rf '$remoteStaging'"
    }
}

# --- Validate archives ------------------------------------------------------
foreach ($a in $archives) {
    $path = Join-Path $StagingDir $a.File
    if (-not (Test-Path $path)) {
        throw "Missing archive: $path"
    }
    $size = (Get-Item $path).Length
    if ($size -lt $MinBytes) {
        throw "Archive too small ($size bytes): $path"
    }
    Write-Host ("   OK {0}: {1:N0} bytes" -f $a.Label, $size) -ForegroundColor Green
}

if ($DumpOnly) {
    Write-Host ""
    Write-Host ">> DumpOnly complete. Archives at: $StagingDir" -ForegroundColor Green
    Write-Host "   Restore later with:"
    Write-Host "   .\scripts\sync-data-from-prod.ps1 -RestoreOnly -StagingDir `"$StagingDir`""
    exit 0
}

# --- Restore to local MongoDB -----------------------------------------------
$mongorestore = Resolve-MongoTool "mongorestore"
$useNative = $null -ne $mongorestore
$restoreHost = Normalize-LocalMongoHost $LocalMongoHost $useNative

Write-Host ">> Checking local MongoDB ${restoreHost}:${LocalMongoPort} ..." -ForegroundColor Cyan
if (-not (Test-TcpPort $restoreHost $LocalMongoPort 5)) {
    throw @"
Local MongoDB is not listening on ${restoreHost}:${LocalMongoPort}.

Start it first (Administrator PowerShell):
  Start-Service MongoDB

Then re-run:
  .\scripts\sync-data-from-prod.ps1 -RestoreOnly -StagingDir `"$StagingDir`"
"@
}

$dropArgs = @()
if (-not $SkipDrop) {
    $dropArgs = @("--drop")
    Write-Host ">> Restore will DROP existing local collections for these DBs." -ForegroundColor Yellow
}

function Invoke-LocalRestore {
    param(
        [string] $ArchivePath,
        [string] $DbName
    )

    $ns = "${DbName}.*"
    if ($useNative) {
        Write-Host ">> mongorestore (native) -> ${restoreHost}:${LocalMongoPort} db=$DbName" -ForegroundColor Cyan
        & $mongorestore `
            --host=$restoreHost `
            --port=$LocalMongoPort `
            --gzip `
            --archive=$ArchivePath `
            --nsInclude=$ns `
            @dropArgs
        if ($LASTEXITCODE -ne 0) {
            throw "mongorestore failed for $DbName (exit $LASTEXITCODE)"
        }
    } else {
        $docker = Get-Command docker -ErrorAction SilentlyContinue
        if (-not $docker) {
            throw "mongorestore not found and Docker unavailable. Install MongoDB Database Tools."
        }
        $dockerHost = if ($LocalMongoHost -eq "127.0.0.1" -or $LocalMongoHost -eq "localhost") {
            "host.docker.internal"
        } else {
            $LocalMongoHost
        }
        $archiveLeaf = Split-Path $ArchivePath -Leaf
        Write-Host ">> mongorestore (docker mongo:7.0) -> ${dockerHost}:${LocalMongoPort} db=$DbName" -ForegroundColor Cyan
        docker run --rm `
            --add-host=host.docker.internal:host-gateway `
            -v "${StagingDir}:/backup" `
            mongo:7.0 `
            mongorestore `
            --host=$dockerHost `
            --port=$LocalMongoPort `
            --gzip `
            --archive=/backup/$archiveLeaf `
            --nsInclude=$ns `
            @dropArgs
        if ($LASTEXITCODE -ne 0) {
            throw "docker mongorestore failed for $DbName (exit $LASTEXITCODE)"
        }
    }
}

foreach ($a in $archives) {
    Invoke-LocalRestore -ArchivePath (Join-Path $StagingDir $a.File) -DbName $a.Db
}

Write-Host ""
Write-Host "=== Prod -> local Mongo sync complete ===" -ForegroundColor Green
Write-Host "Local:    ${restoreHost}:${LocalMongoPort}"
Write-Host "DBs:      $pmDb , $pdfDb"
Write-Host "Archives: $StagingDir"
Write-Host ""
Write-Host "Verify in Compass: mongodb://127.0.0.1:${LocalMongoPort}"
Write-Host ("Or: mongosh --eval ""db.getSiblingDB('{0}').getCollectionNames().length""" -f $pmDb)
