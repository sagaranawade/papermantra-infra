# image-sync — incremental copy papermantraservices/images → pdfgenerator/images
param([switch]$DryRun, [switch]$Deploy)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bash = if (Get-Command bash -ErrorAction SilentlyContinue) { 'bash' } else { 'C:\Program Files\Git\bin\bash.exe' }

$args = @("$ScriptDir/image-sync.sh")
if ($DryRun) { $args += '--dry-run' }
if ($Deploy) { $args += '--deploy' }

& $Bash @args
