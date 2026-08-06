<#
.SYNOPSIS
  Auto-bump vMAJOR.MINOR.PATCH, push the tag, and let CI deploy.

.DESCRIPTION
  Fixed tag format: vX.Y.Z (matches app workflows tags: ['v[0-9]+.[0-9]+.[0-9]+']).

  For each selected app repo this script:
    1. Fetches latest tags from origin
    2. Reads the highest vX.Y.Z tag
    3. Bumps patch by 1 (default) → e.g. v1.0.36 → v1.0.37
    4. Optionally commits dirty files (-CommitMessage)
    5. Pushes branch + new tag
    6. App CI builds the image and dispatches papermantra-infra
       (pin .env + VPS deploy happens automatically)

  Services map to sibling repos next to papermantra-infra:
    portal  → papermantra
    website → robofume
    api     → papermantraservices
    pdf     → pdfgenerator

.EXAMPLE
  # Release PDF only (auto tag)
  .\release.ps1 -Service pdf

.EXAMPLE
  # Preview next tags without pushing
  .\release.ps1 -Service api -DryRun

.EXAMPLE
  # Commit local changes, then tag + push
  .\release.ps1 -Service portal -CommitMessage "Fix login redirect"

.EXAMPLE
  # Bump every app repo independently (each gets its own next patch)
  .\release.ps1 -Service all
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("portal", "website", "api", "pdf", "all")]
    [string] $Service,

    [ValidateSet("patch", "minor", "major")]
    [string] $Bump = "patch",

    # Optional: commit dirty working tree before tagging
    [string] $CommitMessage = "",

    [switch] $DryRun,

    # Allow tagging from a non-main branch (not recommended for prod)
    [switch] $AllowBranch,

    [string] $ReposRoot = ""
)

$ErrorActionPreference = "Stop"

$serviceMap = [ordered]@{
    portal  = "papermantra"
    website = "robofume"
    api     = "papermantraservices"
    pdf     = "pdfgenerator"
}

if (-not $ReposRoot) {
    # .../Git Hub New Repos/papermantra-infra/scripts → parent of infra = Repos root
    $ReposRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

function Get-NextSemverTag {
    param(
        [string] $Latest,
        [ValidateSet("patch", "minor", "major")]
        [string] $BumpKind
    )

    if (-not $Latest) {
        return "v1.0.0"
    }

    if ($Latest -notmatch '^v(?<maj>\d+)\.(?<min>\d+)\.(?<pat>\d+)$') {
        throw "Latest tag '$Latest' is not vMAJOR.MINOR.PATCH"
    }

    $maj = [int]$Matches.maj
    $min = [int]$Matches.min
    $pat = [int]$Matches.pat

    switch ($BumpKind) {
        "major" { $maj++; $min = 0; $pat = 0 }
        "minor" { $min++; $pat = 0 }
        default { $pat++ }
    }

    return "v$maj.$min.$pat"
}

function Get-LatestSemverTag {
    param([string] $RepoPath)

    Push-Location $RepoPath
    try {
        git fetch --tags --force --quiet 2>$null | Out-Null
        $tags = git tag -l "v*.*.*" --sort=-v:refname
        if (-not $tags) { return $null }
        foreach ($t in $tags) {
            $name = "$t".Trim()
            if ($name -match '^v\d+\.\d+\.\d+$') {
                return $name
            }
        }
        return $null
    } finally {
        Pop-Location
    }
}

function Invoke-ReleaseRepo {
    param(
        [string] $SvcName,
        [string] $RepoName
    )

    $repoPath = Join-Path $ReposRoot $RepoName
    if (-not (Test-Path (Join-Path $repoPath ".git"))) {
        throw "Repo not found: $repoPath"
    }

    Write-Host ""
    Write-Host "=== $SvcName ($RepoName) ===" -ForegroundColor Cyan

    Push-Location $repoPath
    try {
        $branch = (git rev-parse --abbrev-ref HEAD).Trim()
        if ($branch -eq "HEAD") {
            throw "Detached HEAD in $RepoName - checkout main first"
        }
        if ($branch -ne "main" -and -not $AllowBranch) {
            throw "On branch '$branch' in $RepoName (expected main). Pass -AllowBranch to override."
        }

        git fetch origin --quiet 2>$null
        $upstream = "origin/$branch"
        $ErrorActionPreference = "Continue"
        git rev-parse --verify $upstream 2>$null | Out-Null
        $hasUpstream = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = "Stop"
        if ($hasUpstream) {
            # Fast-forward local if behind
            $behind = [int]((git rev-list --count "HEAD..$upstream").Trim())
            $ahead = [int]((git rev-list --count "$upstream..HEAD").Trim())
            if ($behind -gt 0 -and $ahead -eq 0) {
                Write-Host "  Fast-forwarding $branch ($behind commits behind)..."
                if (-not $DryRun) {
                    git merge --ff-only $upstream
                }
            } elseif ($behind -gt 0 -and $ahead -gt 0) {
                throw "$RepoName branch '$branch' has diverged from $upstream (ahead $ahead, behind $behind). Rebase/merge first."
            }
        }

        $status = git status --porcelain
        if ($status) {
            Write-Host "  Uncommitted changes:" -ForegroundColor Yellow
            git status --short
            if ($DryRun) {
                Write-Host "  [dry-run] dirty tree ignored for preview" -ForegroundColor DarkYellow
            } elseif (-not $CommitMessage) {
                throw "Working tree dirty in $RepoName. Commit manually or pass -CommitMessage '...'."
            } else {
                Write-Host "  Committing local changes..."
                git add -A
                git commit -m $CommitMessage
                if ($LASTEXITCODE -ne 0) { throw "git commit failed for $RepoName" }
            }
        }

        $latest = Get-LatestSemverTag -RepoPath $repoPath
        $next = Get-NextSemverTag -Latest $latest -BumpKind $Bump

        $lastDisplay = if ($latest) { $latest } else { "(none)" }
        Write-Host ("  last tag : {0}" -f $lastDisplay)
        Write-Host ("  next tag : {0}  (bump={1})" -f $next, $Bump) -ForegroundColor Green
        Write-Host ("  branch   : {0}" -f $branch)

        # Tag already exists?
        $ErrorActionPreference = "Continue"
        git rev-parse --verify "refs/tags/$next" 2>$null | Out-Null
        $tagExists = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = "Stop"
        if ($tagExists) {
            throw "Tag $next already exists locally in $RepoName"
        }

        if ($DryRun) {
            Write-Host ("  [dry-run] would: git push origin {0}; git tag {1}; git push origin {1}" -f $branch, $next)
            return @{ Service = $SvcName; Repo = $RepoName; Tag = $next }
        }

        if ($PSCmdlet.ShouldProcess($RepoName, "push $branch + tag $next")) {
            # Push commits first so the tag points at a remote commit
            git push origin "HEAD:refs/heads/$branch"
            if ($LASTEXITCODE -ne 0) { throw "git push branch failed for $RepoName" }

            git tag -a $next -m "Release $next"
            if ($LASTEXITCODE -ne 0) { throw "git tag failed for $RepoName" }

            git push origin $next
            if ($LASTEXITCODE -ne 0) { throw "git push tag failed for $RepoName" }
        }

        Write-Host "  Pushed $next - CI will build, pin infra .env, and deploy." -ForegroundColor Green
        return @{ Service = $SvcName; Repo = $RepoName; Tag = $next }
    } finally {
        Pop-Location
    }
}

$targets = @()
if ($Service -eq "all") {
    foreach ($k in $serviceMap.Keys) {
        $targets += @{ Service = $k; Repo = $serviceMap[$k] }
    }
} else {
    $targets += @{ Service = $Service; Repo = $serviceMap[$Service] }
}

Write-Host "PaperMantra auto-release" -ForegroundColor Cyan
Write-Host "  repos root : $ReposRoot"
Write-Host "  bump       : $Bump"
Write-Host "  dry-run    : $DryRun"
Write-Host "  services   : $($targets.Service -join ', ')"

$results = New-Object System.Collections.Generic.List[hashtable]
foreach ($t in $targets) {
    $item = Invoke-ReleaseRepo -SvcName $t.Service -RepoName $t.Repo
    if ($item) { [void]$results.Add($item) }
}

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
foreach ($r in $results) {
    Write-Host ("  {0,-8} {1,-22} {2}" -f $r.Service, $r.Repo, $r.Tag)
}

if (-not $DryRun) {
    Write-Host ""
    Write-Host "Watch workflows:" -ForegroundColor DarkGray
    foreach ($r in $results) {
        Write-Host ("  gh run list -R sagaranawade/{0} --limit 3" -f $r.Repo) -ForegroundColor DarkGray
    }
    Write-Host "  gh run list -R sagaranawade/papermantra-infra --limit 3" -ForegroundColor DarkGray
}
