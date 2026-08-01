<#
.SYNOPSIS
  Manually deploy PaperMantra production from your laptop over SSH.

.DESCRIPTION
  You have 5 repos — only 4 are Docker images (each can have its own tag):

    papermantra          → portal   (IMAGE_PAPERMANTRA)
    robofume             → website  (IMAGE_ROBOFUME)
    papermantraservices  → api      (IMAGE_SERVICES)
    pdfgenerator         → pdf      (IMAGE_PDF)
    papermantra-infra    → no image; this script git-pulls it on the VPS

  Pass only the tags you want to update. Unspecified services keep current .env pins.

.EXAMPLE
  # Deploy 4 different tags in one go
  .\manual-deploy.ps1 -WaitForSsh `
    -PortalTag v1.0.77 `
    -WebsiteTag v1.0.29 `
    -ApiTag v1.0.70 `
    -PdfTag v1.0.28

.EXAMPLE
  # Only bump API
  .\manual-deploy.ps1 -WaitForSsh -ApiTag v1.0.71

.EXAMPLE
  # Redeploy current pins (no tag changes) — all app services
  .\manual-deploy.ps1 -WaitForSsh

.EXAMPLE
  # Use local papermantra-infra/.env IMAGE_* tags as the source of truth
  .\manual-deploy.ps1 -WaitForSsh -FromLocalEnv
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $PortalTag = "",
    [string] $WebsiteTag = "",
    [string] $ApiTag = "",
    [string] $PdfTag = "",

    # Legacy single-service mode (still works)
    [ValidateSet("", "all", "portal", "website", "api", "pdf")]
    [string] $Service = "",
    [string] $PinTag = "",

    # Read IMAGE_* tags from local ../.env and pin those on the VPS
    [switch] $FromLocalEnv,

    [string] $ConfigPath = "",
    [switch] $WaitForSsh,
    [int] $WaitTimeoutSec = 180,
    [int] $ConnectTimeoutSec = 10,
    [switch] $SkipGitSync
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-data.config"
}

function Read-Config([string] $path) {
    if (-not (Test-Path $path)) {
        throw "Config not found: $path`nCopy sync-data.config.example to sync-data.config and set VPS_HOST / SSH_KEY."
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

function Normalize-Tag([string] $tag) {
    if (-not $tag) { return "" }
    $t = $tag.Trim()
    if ($t -and -not $t.StartsWith("v")) { $t = "v$t" }
    return $t
}

function Get-TagFromLocalEnv([string] $envPath, [string] $varName) {
    if (-not (Test-Path $envPath)) {
        throw "Local .env not found: $envPath"
    }
    foreach ($line in Get-Content $envPath) {
        $t = $line.Trim()
        if ($t -match "^$varName=.+:(?<tag>[^:\s]+)\s*$") {
            return $Matches["tag"]
        }
    }
    throw "$varName tag not found in $envPath"
}

# --- resolve per-service tags ---
$pins = [ordered]@{
    portal  = Normalize-Tag $PortalTag
    website = Normalize-Tag $WebsiteTag
    api     = Normalize-Tag $ApiTag
    pdf     = Normalize-Tag $PdfTag
}

if ($FromLocalEnv) {
    $localEnv = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
    $pins.portal  = Normalize-Tag (Get-TagFromLocalEnv $localEnv "IMAGE_PAPERMANTRA")
    $pins.website = Normalize-Tag (Get-TagFromLocalEnv $localEnv "IMAGE_ROBOFUME")
    $pins.api     = Normalize-Tag (Get-TagFromLocalEnv $localEnv "IMAGE_SERVICES")
    $pins.pdf     = Normalize-Tag (Get-TagFromLocalEnv $localEnv "IMAGE_PDF")
}

if ($Service -and $PinTag) {
    $t = Normalize-Tag $PinTag
    if ($Service -eq "all") {
        $pins.portal = $t; $pins.website = $t; $pins.api = $t; $pins.pdf = $t
    } else {
        $pins[$Service] = $t
    }
} elseif ($Service -and -not $PinTag -and $Service -ne "all" -and $Service -ne "") {
    # Redeploy one service with whatever is already pinned remotely
}

$cfg = Read-Config $ConfigPath
$vpsHost = $cfg["VPS_HOST"]
$vpsUser = if ($cfg["VPS_USER"]) { $cfg["VPS_USER"] } else { "deploy" }
$vpsPath = if ($cfg["VPS_PATH"]) { $cfg["VPS_PATH"] } else { "/opt/papermantra-infra" }
$sshKey = $cfg["SSH_KEY"]

if (-not $vpsHost) { throw "VPS_HOST missing in $ConfigPath" }
if (-not $sshKey -or -not (Test-Path $sshKey)) {
    throw "SSH_KEY missing or not found: $sshKey"
}

$toPin = @()
$toDeploy = New-Object System.Collections.Generic.List[string]
foreach ($svc in @("portal", "website", "api", "pdf")) {
    if ($pins[$svc]) {
        $toPin += @{ Service = $svc; Tag = $pins[$svc] }
        if (-not $toDeploy.Contains($svc)) { [void]$toDeploy.Add($svc) }
    }
}

# If nothing pinned and user asked for a specific service, redeploy that one.
# If nothing at all → redeploy all four with current remote .env pins.
if ($toDeploy.Count -eq 0) {
    if ($Service -and $Service -ne "all" -and $Service -ne "") {
        [void]$toDeploy.Add($Service)
    } else {
        foreach ($svc in @("portal", "website", "api", "pdf")) { [void]$toDeploy.Add($svc) }
    }
}

Write-Host "Manual deploy -> ${vpsUser}@${vpsHost}" -ForegroundColor Cyan
Write-Host "  path:     $vpsPath"
Write-Host "  services: $($toDeploy -join ',')"
if ($toPin.Count -gt 0) {
    Write-Host "  pins:" -ForegroundColor Cyan
    foreach ($p in $toPin) {
        Write-Host ("    {0,-8} -> {1}" -f $p.Service, $p.Tag)
    }
} else {
    Write-Host "  pins:     (none - keep remote .env tags)"
}

if ($WaitForSsh) {
    Write-Host "Waiting for SSH (VPN/network) up to ${WaitTimeoutSec}s..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort $vpsHost 22 3) {
            Write-Host "  SSH port open." -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 3
    }
}

if (-not (Test-TcpPort $vpsHost 22 $ConnectTimeoutSec)) {
    Write-Host ""
    Write-Host "ERROR: Cannot reach ${vpsHost}:22 from this PC." -ForegroundColor Red
    Write-Host "Connect VPN/network that opens VPS SSH, then:" -ForegroundColor Yellow
    Write-Host "  .\manual-deploy.ps1 -WaitForSsh ..."
    Write-Host "Or diagnose: .\check-vps-access.ps1"
    exit 1
}

$remoteParts = @(
    "set -euo pipefail",
    "cd '$vpsPath'"
)

if (-not $SkipGitSync) {
    $remoteParts += @(
        "git fetch origin main",
        "git reset --hard origin/main",
        "chmod +x scripts/*.sh"
    )
} else {
    $remoteParts += "chmod +x scripts/*.sh"
}

foreach ($p in $toPin) {
    $remoteParts += "./scripts/pin-image-tag.sh $($p.Tag) --service $($p.Service)"
}

$servicesCsv = ($toDeploy -join ",")
$remoteParts += @(
    "export DEPLOY_SERVICES='$servicesCsv'",
    "./scripts/deploy.sh --rollback-on-failure"
)

$remote = ($remoteParts -join "; ")

$sshArgs = @(
    "-i", $sshKey,
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=$ConnectTimeoutSec",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=4",
    "${vpsUser}@${vpsHost}",
    $remote
)

Write-Host ""
Write-Host "Running remote deploy..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess("${vpsUser}@${vpsHost}", "pin + deploy ($servicesCsv)")) {
    & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Remote deploy failed (exit $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "Deploy finished." -ForegroundColor Green
Write-Host "  https://papermantra.com"
Write-Host "  https://api.papermantra.com/papermantra/actuator/health"
Write-Host "  https://pdf.papermantra.com/pdfgenerator/actuator/health"
Write-Host "  https://neelmind.com"
Write-Host ""
Write-Host "Tip: after a successful deploy, commit updated IMAGE_* lines in papermantra-infra/.env so pull-deploy / next runs stay in sync." -ForegroundColor DarkGray
