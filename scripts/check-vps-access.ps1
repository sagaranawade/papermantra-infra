<#
.SYNOPSIS
  Diagnose why VPS SSH / Mongo tunnels fail from this PC.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [int] $TimeoutSec = 5
)

$ErrorActionPreference = "Continue"

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot "sync-data.config"
}

$vpsHost = "187.127.189.114"
if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match '^\s*VPS_HOST=(.+)$') { $vpsHost = $Matches[1].Trim() }
    }
}

function Test-Tcp([string] $h, [int] $p, [int] $sec) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($h, $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($sec), $false)
        if (-not $ok) { $c.Close(); return $false }
        $c.EndConnect($iar); $c.Close(); return $true
    } catch { return $false }
}

Write-Host "VPS origin: $vpsHost" -ForegroundColor Cyan
foreach ($port in 22, 80, 443) {
    $ok = Test-Tcp $vpsHost $port $TimeoutSec
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("  TCP {0,-4}  {1}" -f $port, $(if ($ok) { "OPEN" } else { "TIMEOUT/BLOCKED" })) -ForegroundColor $color
}

Write-Host ""
Write-Host "Cloudflare / public site:" -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -Uri "https://api.papermantra.com/papermantra/actuator/health" -UseBasicParsing -TimeoutSec 15
    Write-Host "  api.papermantra.com health HTTP $($r.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "  api.papermantra.com health FAILED: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
if (-not (Test-Tcp $vpsHost 22 $TimeoutSec)) {
    Write-Host "Diagnosis: origin IP is unreachable from this network." -ForegroundColor Yellow
    Write-Host "Use Cloudflare Access for Mongo: .\mongo-access-cloudflare.ps1" -ForegroundColor Yellow
    Write-Host "See docs/MONGO-ACCESS.md" -ForegroundColor Yellow
} else {
    Write-Host "SSH port is reachable - .\mongo-tunnel.ps1 should work." -ForegroundColor Green
}
