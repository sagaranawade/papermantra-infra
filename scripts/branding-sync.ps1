# branding-sync — copy papermantraservices/user-uploads to prod staging + volume
param([switch]$DryRun, [switch]$Deploy)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bash = if (Get-Command bash -ErrorAction SilentlyContinue) { 'bash' } else { 'C:\Program Files\Git\bin\bash.exe' }

$args = @("$ScriptDir/branding-sync.sh")
if ($DryRun) { $args += '--dry-run' }
if ($Deploy) { $args += '--deploy' }

& $Bash @args
