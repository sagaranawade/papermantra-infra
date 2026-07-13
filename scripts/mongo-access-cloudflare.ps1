<#
.SYNOPSIS
  Cloudflare Access TCP client for Mongo (OPTIONAL).

.DESCRIPTION
  Only works AFTER you create DNS + Zero Trust tunnel for the hostname.
  If you have not done that, use .\mongo-tunnel.ps1 instead (SSH tunnel).

  Error "lookup ... no such host" means the hostname does not exist in DNS yet.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $Hostname = "",
    [int] $LocalPort = 27018,
    [switch] $PrintOnly
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-data.config"
}

function Read-Config([string] $path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith("#")) { return }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { return }
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
    return $map
}

$config = Read-Config $ConfigPath
if (-not $Hostname) { $Hostname = $config["MONGO_CF_HOSTNAME"] }

if (-not $Hostname) {
    Write-Host "Cloudflare Mongo hostname is not configured." -ForegroundColor Red
    Write-Host ""
    Write-Host "Daily permanent path (use this):" -ForegroundColor Green
    Write-Host "  .\mongo-tunnel.ps1"
    Write-Host ""
    Write-Host "Cloudflare Access is optional and needs one-time setup:" -ForegroundColor Yellow
    Write-Host "  1. Create Zero Trust tunnel -> tcp://127.0.0.1:27017"
    Write-Host "  2. Add DNS CNAME e.g. mongo.papermantra.com"
    Write-Host "  3. Set MONGO_CF_HOSTNAME=mongo.papermantra.com in sync-data.config"
    Write-Host "  4. See docs/MONGO-ACCESS.md"
    throw "MONGO_CF_HOSTNAME not set. Use mongo-tunnel.ps1."
}

# Fail fast if DNS missing (avoids endless error spam).
try {
    $null = [System.Net.Dns]::GetHostEntry($Hostname)
} catch {
    Write-Host "DNS lookup failed for $Hostname (no such host)." -ForegroundColor Red
    Write-Host "That hostname was never created in Cloudflare DNS." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Use the working permanent path instead:" -ForegroundColor Green
    Write-Host "  .\mongo-tunnel.ps1"
    throw "Hostname $Hostname does not resolve."
}

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cloudflared) {
    throw "cloudflared not in PATH. Install: winget install --id Cloudflare.cloudflared"
}

Write-Host "=== Cloudflare Access TCP (optional) ===" -ForegroundColor Green
Write-Host "Hostname: $Hostname"
Write-Host "Local:    127.0.0.1:$LocalPort"
Write-Host "Prefer SSH tunnel unless you finished Zero Trust setup: .\mongo-tunnel.ps1"
Write-Host ""

if ($PrintOnly) { exit 0 }

& cloudflared access tcp --hostname $Hostname --url "127.0.0.1:$LocalPort"
