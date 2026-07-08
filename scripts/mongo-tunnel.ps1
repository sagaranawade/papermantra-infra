<#
.SYNOPSIS
  SSH tunnel from this PC to production MongoDB (Docker) on the VPS.

.DESCRIPTION
  Mongo is NOT published on the VPS host (backend Docker network only).
  This script:
    1. Reads VPS SSH settings from scripts/sync-data.config
    2. Starts a temporary socat helper on the VPS bound to 127.0.0.1:27017
       (joins the compose backend network and forwards to papermantra-mongodb)
    3. Opens local tunnel: localhost:<LocalPort> -> VPS 127.0.0.1:27017
    4. Removes the helper when the tunnel stops (Ctrl+C)

  Keep this window open while Compass / mongosh / IntelliJ are connected.

.EXAMPLE
  .\scripts\mongo-tunnel.ps1

.EXAMPLE
  .\scripts\mongo-tunnel.ps1 -LocalPort 27018
#>
[CmdletBinding()]
param(
    [int] $LocalPort = 27018,
    [string] $ConfigPath = "",
    [string] $MongoContainer = "papermantra-mongodb",
    [string] $DockerNetwork = "papermantra_backend",
    [string] $HelperName = "mongo-ssh-tunnel-helper",
    [int] $VpsLocalPort = 27017,
    [switch] $PrintOnly
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-data.config"
}

function Read-Config([string] $path) {
    if (-not (Test-Path $path)) {
        throw "Config not found: $path`nCopy sync-data.config.example to sync-data.config and set VPS_HOST / VPS_USER / SSH_KEY."
    }
    $map = @{}
    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
    return $map
}

function Read-DotEnvValue([string] $envPath, [string] $key) {
    if (-not (Test-Path $envPath)) { return $null }
    foreach ($line in Get-Content $envPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ($t.StartsWith("$key=")) {
            return $t.Substring($key.Length + 1).Trim()
        }
    }
    return $null
}

function Invoke-Vps([string[]] $sshArgs, [string] $remoteCommand) {
    # Normalize to LF so PowerShell CRLF heredocs / multiline strings never break remote bash.
    $normalized = ($remoteCommand -replace "`r`n", "`n" -replace "`r", "`n").Trim()
    $output = & ssh @sshArgs $normalized 2>&1
    $text = ($output | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Remote SSH command failed (exit $LASTEXITCODE): $normalized`n$text"
    }
    return $text
}

$config = Read-Config $ConfigPath
$vpsHost = $config["VPS_HOST"]
$vpsUser = if ($config["VPS_USER"]) { $config["VPS_USER"] } else { "deploy" }
$sshKey = $config["SSH_KEY"]
$vpsPath = if ($config["VPS_PATH"]) { $config["VPS_PATH"] } else { "/opt/papermantra-infra" }

if (-not $vpsHost) { throw "VPS_HOST missing in $ConfigPath" }
if (-not $sshKey -or -not (Test-Path $sshKey)) {
    throw "SSH_KEY missing or not found: $sshKey"
}

$envFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
$mongoUser = Read-DotEnvValue $envFile "MONGO_ROOT_USER"
$mongoPass = Read-DotEnvValue $envFile "MONGO_ROOT_PASSWORD"
$mongoDb = Read-DotEnvValue $envFile "MONGODB_DATABASE"
$pdfDb = Read-DotEnvValue $envFile "PDF_MONGODB_DATABASE"
if (-not $mongoUser) { $mongoUser = "admin" }
if (-not $mongoDb) { $mongoDb = "papermantra" }
if (-not $pdfDb) { $pdfDb = "pdfgenerator" }

if (-not $PrintOnly) {
    $existing = @(Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        throw "Local port $LocalPort is already in use (PID $($existing[0].OwningProcess)). Stop that process or pass -LocalPort 27019."
    }
}

$sshArgs = @(
    "-i", $sshKey,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "${vpsUser}@${vpsHost}"
)

Write-Host "Checking Mongo container on VPS ($vpsHost)..." -ForegroundColor Cyan
$running = Invoke-Vps $sshArgs "docker inspect -f '{{.State.Running}}' $MongoContainer"
if ($running -ne "true") {
    throw "Container '$MongoContainer' is not running on the VPS."
}

$uri = "mongodb://${mongoUser}:****@127.0.0.1:${LocalPort}/${mongoDb}?authSource=admin"
$uriFull = $null
if ($mongoPass) {
    $encPass = [uri]::EscapeDataString($mongoPass)
    $uriFull = "mongodb://${mongoUser}:${encPass}@127.0.0.1:${LocalPort}/${mongoDb}?authSource=admin"
}

Write-Host ""
Write-Host "=== Prod Mongo SSH tunnel ===" -ForegroundColor Green
Write-Host "SSH:            ${vpsUser}@${vpsHost}"
Write-Host "Container:      $MongoContainer"
Write-Host "Docker network: $DockerNetwork"
Write-Host "Local bind:     127.0.0.1:$LocalPort"
Write-Host "Auth DB:        admin"
Write-Host "Username:       $mongoUser"
Write-Host "Password:       (from papermantra-infra/.env MONGO_ROOT_PASSWORD)"
Write-Host "Databases:      $mongoDb , $pdfDb"
Write-Host ""
Write-Host "Compass / Studio 3T:" -ForegroundColor Yellow
Write-Host "  Host:                 127.0.0.1"
Write-Host "  Port:                 $LocalPort"
Write-Host "  Authentication:       Username / Password"
Write-Host "  Username:             $mongoUser"
Write-Host "  Password:             <MONGO_ROOT_PASSWORD from .env>"
Write-Host "  Auth Source:          admin"
Write-Host "  Authentication DB:    admin"
Write-Host ""
Write-Host "Connection string (authSource=admin):" -ForegroundColor Yellow
Write-Host "  $uri"
if ($uriFull) {
    Write-Host ""
    Write-Host "Full URI (password included - do not share/commit):" -ForegroundColor DarkYellow
    Write-Host "  $uriFull"
}
Write-Host ""
Write-Host "mongosh example:" -ForegroundColor Yellow
$mongoshExample = '  mongosh "mongodb://' + $mongoUser + ':<PASSWORD>@127.0.0.1:' + $LocalPort + '/' + $mongoDb + '?authSource=admin"'
Write-Host $mongoshExample
Write-Host ""
Write-Host "VPS stack path: $vpsPath"
Write-Host ""

if ($PrintOnly) {
    Write-Host "-PrintOnly set; not opening tunnel." -ForegroundColor Cyan
    exit 0
}

# Bind helper only on VPS loopback so Mongo is never exposed publicly.
# Must be a SINGLE line: Windows CRLF + bash "\" continuations become "alpine/socat\r"
# which Docker rejects with "invalid reference format".
$startHelper = (
    "docker rm -f $HelperName >/dev/null 2>&1 || true; " +
    "docker run -d --rm --name $HelperName " +
    "--network $DockerNetwork " +
    "-p 127.0.0.1:${VpsLocalPort}:27017 " +
    "alpine/socat " +
    "TCP-LISTEN:27017,fork,reuseaddr TCP:${MongoContainer}:27017"
)

Write-Host "Starting temporary VPS helper ($HelperName) on 127.0.0.1:$VpsLocalPort ..." -ForegroundColor Cyan
try {
    Invoke-Vps $sshArgs $startHelper | Out-Null
} catch {
    Write-Host "Helper start failed with network '$DockerNetwork'. Listing Docker networks..." -ForegroundColor Yellow
    try { Invoke-Vps $sshArgs "docker network ls" | Write-Host } catch { }
    throw
}

$helperOk = $false
try {
    Start-Sleep -Seconds 1
    $helperRunning = Invoke-Vps $sshArgs "docker inspect -f '{{.State.Running}}' $HelperName"
    if ($helperRunning -ne "true") {
        throw "Helper container '$HelperName' did not start."
    }
    $helperOk = $true

    Write-Host "Opening tunnel (Ctrl+C to stop)..." -ForegroundColor Cyan
    Write-Host "ssh -N -L ${LocalPort}:127.0.0.1:${VpsLocalPort} ${vpsUser}@${vpsHost}"
    & ssh @(
        "-i", $sshKey,
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-N",
        "-L", "${LocalPort}:127.0.0.1:${VpsLocalPort}",
        "${vpsUser}@${vpsHost}"
    )
}
finally {
    if ($helperOk) {
        Write-Host ""
        Write-Host "Cleaning up VPS helper ($HelperName)..." -ForegroundColor Cyan
        & ssh @sshArgs "docker rm -f $HelperName >/dev/null 2>&1 || true" | Out-Null
    }
}
