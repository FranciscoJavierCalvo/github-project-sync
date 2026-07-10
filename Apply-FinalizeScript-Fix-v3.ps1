#requires -version 5.1

<#
.SYNOPSIS
    Fixes Add-UniqueLine in Finalize-GitHubProjectSyncProject.ps1.

.DESCRIPTION
    This patch fixes the .gitignore update failure caused by an empty Lines value.

.NOTES
    After the finalisation script works, this patch script can be removed.
#>

$ErrorActionPreference = "Stop"

$targetScript = Join-Path -Path (Get-Location).Path -ChildPath "Finalize-GitHubProjectSyncProject.ps1"

if (-not (Test-Path -LiteralPath $targetScript)) {
    Write-Host "Finalize-GitHubProjectSyncProject.ps1 was not found in the current folder." -ForegroundColor Red
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$targetScript.fix_v3_backup_$timestamp.bak"

Copy-Item -LiteralPath $targetScript -Destination $backupPath -Force

Write-Host "Backup created:" -ForegroundColor Green
Write-Host $backupPath

$content = Get-Content -LiteralPath $targetScript -Raw

$pattern = '(?s)function Add-UniqueLine\s*\{.*?\r?\n\}\s*\r?\n\r?\n# ------------------------------------------------------------\r?\n# Validate location'

$replacement = @'
function Add-UniqueLine {
    param(
        [AllowNull()]
        [string[]]$Lines,

        [AllowNull()]
        [string]$Line
    )

    $workingLines = @()

    if ($null -ne $Lines) {
        foreach ($existing in @($Lines)) {
            $workingLines += [string]$existing
        }
    }

    if ($null -eq $Line) {
        $Line = ""
    }

    if ($Line.Trim().Length -eq 0) {
        return @($workingLines + "")
    }

    foreach ($existingLine in $workingLines) {
        if ($existingLine.Trim().ToLower() -eq $Line.Trim().ToLower()) {
            return $workingLines
        }
    }

    return @($workingLines + $Line)
}

# ------------------------------------------------------------
# Validate location
'@

$newContent = :Replace($content, $pattern, $replacement, 1)

if ($newContent -eq $content) {
    Write-Host "Could not find the Add-UniqueLine function block to replace." -ForegroundColor Red
    Write-Host "No changes were applied." -ForegroundColor Yellow
    exit 1
}

Set-Content -LiteralPath $targetScript -Value $newContent -Encoding UTF8

Write-Host ""
Write-Host "Finalize script fixed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host ".\Finalize-GitHubProjectSyncProject.ps1"
