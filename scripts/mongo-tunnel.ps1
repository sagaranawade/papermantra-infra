<#
.SYNOPSIS
  SSH tunnel from this PC to production MongoDB (Docker) on the VPS.

.DESCRIPTION
  Mongo is NOT published on the VPS host (backend Docker network only).
  This script:
    1. Reads VPS SSH settings from scripts/sync-data.config
    2. Resolves the Mongo container IP on the compose backend network
    3. Opens local tunnel: localhost:<LocalPort> -> VPS <mongo-ip>:27017
       (SSH forwards through the VPS into the Docker backend network)

  No extra Docker images (socat) are required on the VPS.

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
    [string] $DockerNetwork = "",
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
    # Normalize to LF so PowerShell CRLF never breaks remote bash.
    $normalized = ($remoteCommand -replace "`r`n", "`n" -replace "`r", "`n").Trim()
    $output = & ssh @sshArgs $normalized 2>&1
    $text = ($output | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Remote SSH command failed (exit $LASTEXITCODE): $normalized`n$text"
    }
    return $text
}

function Resolve-MongoEndpoint([string[]] $sshArgs, [string] $container, [string] $preferredNetwork) {
    $format = '{{range $k, $v := .NetworkSettings.Networks}}{{if $v.IPAddress}}{{$k}}={{$v.IPAddress}}{{println}}{{end}}{{end}}'
    $lines = Invoke-Vps $sshArgs "docker inspect -f '$format' $container"

    $endpoints = @()
    foreach ($line in ($lines -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line.Split("=", 2)
        if ($parts.Count -eq 2 -and $parts[1] -match '^\d+\.\d+\.\d+\.\d+$') {
            $endpoints += @{ Network = $parts[0]; Ip = $parts[1] }
        }
    }

    if ($endpoints.Count -eq 0) {
        throw "Could not resolve Mongo container IP for '$container'. Is it attached to a Docker network?"
    }

    if ($preferredNetwork) {
        $match = $endpoints | Where-Object { $_.Network -eq $preferredNetwork } | Select-Object -First 1
        if ($match) { return $match }
    }

    $backend = $endpoints | Where-Object { $_.Network -like '*_backend' } | Select-Object -First 1
    if ($backend) { return $backend }

    return $endpoints[0]
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

if (-not $DockerNetwork) {
    $composeProject = Read-DotEnvValue (Join-Path (Split-Path $PSScriptRoot -Parent) ".env") "COMPOSE_PROJECT_NAME"
    if (-not $composeProject) { $composeProject = "papermantra" }
    $DockerNetwork = "${composeProject}_backend"
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

Write-Host "Resolving Mongo IP on Docker network..." -ForegroundColor Cyan
$endpoint = Resolve-MongoEndpoint $sshArgs $MongoContainer $DockerNetwork
$mongoIp = $endpoint.Ip
$dockerNetwork = $endpoint.Network

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
Write-Host "Docker network: $dockerNetwork"
Write-Host "Container IP:   $mongoIp"
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

Write-Host "Opening tunnel (Ctrl+C to stop)..." -ForegroundColor Cyan
Write-Host "ssh -N -L ${LocalPort}:${mongoIp}:27017 ${vpsUser}@${vpsHost}"
& ssh @(
    "-i", $sshKey,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-N",
    "-L", "${LocalPort}:${mongoIp}:27017",
    "${vpsUser}@${vpsHost}"
)
