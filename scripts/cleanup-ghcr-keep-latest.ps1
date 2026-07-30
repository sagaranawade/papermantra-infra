<#
.SYNOPSIS
  Delete old GHCR container package versions; keep only the newest N per package.

.DESCRIPTION
  Requires a GitHub PAT with: read:packages, delete:packages, repo (optional).
  Create at: https://github.com/settings/tokens

  Usage:
    $env:GH_TOKEN = "ghp_...."   # or: gh auth login -s read:packages,delete:packages,write:packages
    .\scripts\cleanup-ghcr-keep-latest.ps1
    .\scripts\cleanup-ghcr-keep-latest.ps1 -Keep 2 -WhatIf
    .\scripts\cleanup-ghcr-keep-latest.ps1 -Packages papermantraservices,papermantra,pdfgenerator

.NOTES
  "Latest 2" = 2 most recently updated package VERSIONS (each version may carry
  tags like v1.0.58 and/or latest). Older versions are deleted.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [int]$Keep = 2,
  [string[]]$Packages = @(
    "papermantraservices",
    "papermantra",
    "pdfgenerator",
    "robofume"
  ),
  [string]$Owner = "sagaranawade"
)

$ErrorActionPreference = "Stop"

if (-not $env:GH_TOKEN -and -not $env:GITHUB_TOKEN) {
  Write-Host "ERROR: Set GH_TOKEN (PAT with read:packages + delete:packages)." -ForegroundColor Red
  Write-Host "  `$env:GH_TOKEN = 'ghp_...'"
  Write-Host "  Or: gh auth login -s read:packages,delete:packages,write:packages"
  exit 1
}

$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
$headers = @{
  Authorization = "Bearer $token"
  Accept        = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"  = "papermantra-ghcr-cleanup"
}

function Get-PackageVersions([string]$name) {
  $all = @()
  $page = 1
  do {
    $uri = "https://api.github.com/users/$Owner/packages/container/$name/versions?per_page=100&page=$page"
    try {
      $batch = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
    } catch {
      $status = $_.Exception.Response.StatusCode.value__
      if ($status -eq 404) {
        Write-Host "  package not found: $name (skip)" -ForegroundColor Yellow
        return @()
      }
      throw
    }
    if (-not $batch -or $batch.Count -eq 0) { break }
    $all += $batch
    $page++
  } while ($batch.Count -eq 100)
  return $all
}

Write-Host "Owner=$Owner Keep=$Keep WhatIf=$WhatIfPreference"
Write-Host "Packages: $($Packages -join ', ')"
Write-Host ""

$totalDeleted = 0
$totalKept = 0

foreach ($pkg in $Packages) {
  Write-Host "=== $pkg ===" -ForegroundColor Cyan
  $versions = @(Get-PackageVersions $pkg)
  if ($versions.Count -eq 0) { continue }

  $sorted = $versions | Sort-Object { $_.updated_at } -Descending
  $keepList = @($sorted | Select-Object -First $Keep)
  $deleteList = @($sorted | Select-Object -Skip $Keep)

  foreach ($v in $keepList) {
    $tags = @($v.metadata.container.tags) -join ", "
    if (-not $tags) { $tags = "(untagged)" }
    Write-Host "  KEEP  id=$($v.id) updated=$($v.updated_at) tags=[$tags]" -ForegroundColor Green
    $totalKept++
  }

  foreach ($v in $deleteList) {
    $tags = @($v.metadata.container.tags) -join ", "
    if (-not $tags) { $tags = "(untagged)" }
    $msg = "DELETE id=$($v.id) updated=$($v.updated_at) tags=[$tags]"
    if ($PSCmdlet.ShouldProcess("$pkg@$($v.id)", $msg)) {
      $uri = "https://api.github.com/users/$Owner/packages/container/$pkg/versions/$($v.id)"
      Invoke-RestMethod -Uri $uri -Headers $headers -Method DELETE | Out-Null
      Write-Host "  $msg" -ForegroundColor DarkYellow
      $totalDeleted++
    } else {
      Write-Host "  WOULD $msg" -ForegroundColor DarkYellow
      $totalDeleted++
    }
  }
  Write-Host ""
}

Write-Host "Done. kept=$totalKept deleted_or_planned=$totalDeleted"
Write-Host "Tip: run once with -WhatIf first, then without -WhatIf to apply."
