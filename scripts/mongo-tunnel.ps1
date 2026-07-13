<#
.SYNOPSIS
  Permanent daily access to production MongoDB via SSH tunnel.

.DESCRIPTION
  Forwards local 127.0.0.1:<LocalPort> to VPS 127.0.0.1:27017
  (Mongo published loopback-only in docker-compose).

  Keep this window open. Connect Compass to 127.0.0.1:<LocalPort>.

.EXAMPLE
  .\mongo-tunnel.ps1
#>
[CmdletBinding()]
param(
    [int] $LocalPort = 27018,
    [string] $ConfigPath = "",
    [string] $MongoContainer = "papermantra-mongodb",
    [int] $ConnectTimeoutSec = 10,
    [int] $RemoteCmdTimeoutSec = 15,
    [switch] $PrintOnly,
    [switch] $EnsureLoopback,
    # Skip docker inspect preflight (use when SSH hangs on remote commands).
    [switch] $SkipMongoCheck
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-data.config"
}

function Read-Config([string] $path) {
    if (-not (Test-Path $path)) {
        throw "Config not found: $path"
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

function Test-TcpPort([string] $hostName, [int] $port, [int] $timeoutSec) {
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

function Get-SshArgs([string] $key, [string] $userAtHost, [int] $timeoutSec) {
    return @(
        "-i", $key,
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=$timeoutSec",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        $userAtHost
    )
}

function Invoke-Ssh([string[]] $sshArgs, [string] $remote, [int] $timeoutSec = 15) {
    # ConnectTimeout only covers TCP connect — wrap the whole remote call so a
    # hung docker/sshd session cannot block forever.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $job = Start-Job -ScriptBlock {
            param($argsList, $cmd)
            $out = & ssh @argsList $cmd 2>&1
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Text     = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
            }
        } -ArgumentList @(, $sshArgs), $remote

        $done = Wait-Job $job -Timeout $timeoutSec
        if (-not $done) {
            Stop-Job $job -Force -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            return @{
                ExitCode = 124
                Text     = "SSH remote command timed out after ${timeoutSec}s: $remote"
            }
        }
        $result = Receive-Job $job
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if ($null -eq $result) {
            return @{ ExitCode = 1; Text = "SSH returned no output" }
        }
        return @{ ExitCode = [int]$result.ExitCode; Text = [string]$result.Text }
    } finally {
        $ErrorActionPreference = $prev
    }
}

$config = Read-Config $ConfigPath
$vpsHost = $config["VPS_HOST"]
$vpsUser = if ($config["VPS_USER"]) { $config["VPS_USER"] } else { "deploy" }
$sshKey = $config["SSH_KEY"]
$vpsPath = if ($config["VPS_PATH"]) { $config["VPS_PATH"] } else { "/opt/papermantra-infra" }
$userAtHost = "${vpsUser}@${vpsHost}"

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

Write-Host "Preflight: TCP ${vpsHost}:22 ..." -ForegroundColor Cyan
if (-not (Test-TcpPort $vpsHost 22 $ConnectTimeoutSec)) {
    Write-Host "SSH port 22 is blocked from this network." -ForegroundColor Red
    Write-Host "Open your VPS provider firewall for TCP 22 from your IP, then retry." -ForegroundColor Yellow
    throw "Cannot reach ${vpsHost}:22"
}

if (-not $PrintOnly) {
    $busy = @(Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        throw "Local port $LocalPort in use (PID $($busy[0].OwningProcess)). Use -LocalPort 27019"
    }
}

$sshArgs = Get-SshArgs $sshKey $userAtHost $ConnectTimeoutSec

# Default target: compose publishes Mongo on host loopback only.
$forwardTarget = "127.0.0.1:27017"
$mode = "loopback"

if ($SkipMongoCheck) {
    Write-Host "Skipping Mongo container preflight (-SkipMongoCheck)." -ForegroundColor Yellow
} else {
    Write-Host "Checking Mongo container (timeout ${RemoteCmdTimeoutSec}s)..." -ForegroundColor Cyan
    $running = Invoke-Ssh $sshArgs "docker inspect -f '{{.State.Running}}' $MongoContainer" $RemoteCmdTimeoutSec
    if ($running.ExitCode -eq 124) {
        Write-Host $running.Text -ForegroundColor Yellow
        Write-Host "Remote docker check hung. Falling back to loopback tunnel." -ForegroundColor Yellow
        Write-Host "Tip: next time use  .\mongo-tunnel.ps1 -SkipMongoCheck" -ForegroundColor DarkYellow
    } elseif ($running.ExitCode -ne 0 -or $running.Text -ne "true") {
        Write-Host "Container '$MongoContainer' check failed: $($running.Text)" -ForegroundColor Yellow
        Write-Host "Continuing with loopback 127.0.0.1:27017 anyway..." -ForegroundColor Yellow
    } else {
        # Prefer host loopback if published; else container IP.
        $loop = Invoke-Ssh $sshArgs "ss -lnt | grep 127.0.0.1:27017 || true" $RemoteCmdTimeoutSec
        if ($loop.Text -match '127\.0\.0\.1:27017') {
            $forwardTarget = "127.0.0.1:27017"
            $mode = "loopback"
        } else {
            $ipResult = Invoke-Ssh $sshArgs "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $MongoContainer" $RemoteCmdTimeoutSec
            if ($ipResult.ExitCode -eq 0 -and $ipResult.Text -match '(\d+\.\d+\.\d+\.\d+)') {
                $mongoIp = $Matches[1]
                $forwardTarget = "${mongoIp}:27017"
                $mode = "container-ip"
            } elseif ($EnsureLoopback) {
                Write-Host "Publishing Mongo on 127.0.0.1:27017 via compose..." -ForegroundColor Cyan
                $ensure = Invoke-Ssh $sshArgs "cd $vpsPath && git pull origin main && docker compose up -d mongodb" 60
                Write-Host $ensure.Text
                Start-Sleep -Seconds 2
                $loop2 = Invoke-Ssh $sshArgs "ss -lnt | grep 127.0.0.1:27017 || true" $RemoteCmdTimeoutSec
                if ($loop2.Text -match '127\.0\.0\.1:27017') {
                    $forwardTarget = "127.0.0.1:27017"
                    $mode = "loopback"
                } else {
                    Write-Host "Loopback not up; tunnel may fail until Mongo is published on 127.0.0.1:27017." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Could not confirm loopback publish; using 127.0.0.1:27017." -ForegroundColor Yellow
            }
        }
    }
}

$uri = "mongodb://${mongoUser}:****@127.0.0.1:${LocalPort}/${mongoDb}?authSource=admin"
$uriFull = $null
if ($mongoPass) {
    $encPass = [uri]::EscapeDataString($mongoPass)
    $uriFull = "mongodb://${mongoUser}:${encPass}@127.0.0.1:${LocalPort}/${mongoDb}?authSource=admin"
}

Write-Host ""
Write-Host "=== Prod Mongo SSH tunnel (permanent daily path) ===" -ForegroundColor Green
Write-Host "SSH:            $userAtHost"
Write-Host "Mode:           $mode -> $forwardTarget"
Write-Host "Local bind:     127.0.0.1:$LocalPort"
Write-Host "Username:       $mongoUser"
Write-Host "Auth source:    admin"
Write-Host "Databases:      $mongoDb , $pdfDb"
Write-Host "Password:       papermantra-infra/.env MONGO_ROOT_PASSWORD"
Write-Host ""
Write-Host "Compass:" -ForegroundColor Yellow
Write-Host "  Host 127.0.0.1   Port $LocalPort   User $mongoUser   Auth DB admin"
Write-Host "URI: $uri"
if ($uriFull) {
    Write-Host "Full URI (do not share): $uriFull" -ForegroundColor DarkYellow
}
Write-Host ""

if ($PrintOnly) {
    Write-Host "-PrintOnly set; not opening tunnel." -ForegroundColor Cyan
    exit 0
}

Write-Host "Opening tunnel. Leave this window open. Ctrl+C to stop." -ForegroundColor Cyan
Write-Host "ssh -N -L ${LocalPort}:${forwardTarget} $userAtHost"
& ssh @(
    "-i", $sshKey,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=$ConnectTimeoutSec",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "TCPKeepAlive=yes",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-N",
    "-L", "${LocalPort}:${forwardTarget}",
    $userAtHost
)
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Tunnel exited (code $LASTEXITCODE). Common causes:" -ForegroundColor Red
    Write-Host "  - VPS/firewall reset the SSH session (Connection reset)"
    Write-Host "  - Mongo not listening on $forwardTarget"
    Write-Host "  - Local port $LocalPort already in use"
    Write-Host "Retry:  .\mongo-tunnel.ps1 -SkipMongoCheck" -ForegroundColor Yellow
    exit $LASTEXITCODE
}
