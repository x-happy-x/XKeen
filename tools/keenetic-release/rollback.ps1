param([string]$Router = 'keenetic', [Parameter(Mandatory=$true)][string]$Backup, [switch]$Check)
$ErrorActionPreference = 'Stop'
if ($Backup -notmatch '^/opt/backups/homenet-[0-9A-Za-z_-]+$') { throw 'Invalid backup path' }
$mode = if ($Check) { '--check' } else { '--apply' }
& ssh -o BatchMode=yes -o ConnectTimeout=10 $Router "sh '$Backup/rollback.sh' $mode"
if ($LASTEXITCODE -ne 0) { throw "Rollback failed; inspect $Backup/rollback.log on router" }
