#requires -version 5.1

<#
.SYNOPSIS
    Fixes Add-UniqueLine in Finalize-GitHubProjectSyncProject.ps1.

.DESCRIPTION
    Replaces the Add-UniqueLine function with a safer version that handles:
    - empty .gitignore
    - null line arrays
    - blank lines
    - duplicate entries

.NOTES
    This is a patch script.
    After the finalisation script works, this patch script can be removed.
#>

$ErrorActionPreference = "Stop"

$targetScript = Join-Path -Path (Get-Location).Path -ChildPath "Finalize-GitHubProjectSyncProject.ps1"

if (-not (Test-Path -LiteralPath $targetScript)) {
    Write-Host "Finalize-GitHubProjectSyncProject.ps1 was not found in the current folder." -ForegroundColor Red
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$targetScript.fix_v4_backup_$timestamp.bak"

Copy-Item -LiteralPath $targetScript -Destination $backupPath -Force

Write-Host "Backup created:" -ForegroundColor Green
Write-Host $backupPath

$content = Get-Content -LiteralPath $targetScript -Raw

$startMarker = "function Add-UniqueLine {"
$validateMarker = "# Validate location"
$separatorMarker = "# ------------------------------------------------------------"

$startIndex = $content.IndexOf($startMarker)

if ($startIndex -lt 0) {
    Write-Host "Could not find Add-UniqueLine function start." -ForegroundColor Red
    exit 1
}

$validateIndex = $content.IndexOf($validateMarker, $startIndex)

if ($validateIndex -lt 0) {
    Write-Host "Could not find Validate location marker after Add-UniqueLine." -ForegroundColor Red
    exit 1
}

$separatorIndex = $content.LastIndexOf($separatorMarker, $validateIndex)

if ($separatorIndex -lt 0 -or $separatorIndex -le $startIndex) {
    Write-Host "Could not find separator before Validate location marker." -ForegroundColor Red
    exit 1
}

$replacementLines = @(
'function Add-UniqueLine {',
'    param(',
'        [AllowNull()]',
'        [string[]]$Lines,',
'',
'        [AllowNull()]',
'        [string]$Line',
'    )',
'',
'    $workingLines = @()',
'',
'    if ($null -ne $Lines) {',
'        foreach ($existingLine in @($Lines)) {',
'            if ($null -ne $existingLine) {',
'                $workingLines += [string]$existingLine',
'            }',
'            else {',
'                $workingLines += ""',
'            }',
'        }',
'    }',
'',
'    if ($null -eq $Line) {',
'        $Line = ""',
'    }',
'',
'    if ($Line.Trim().Length -eq 0) {',
'        $workingLines += ""',
'        return $workingLines',
'    }',
'',
'    foreach ($existingLine in $workingLines) {',
'        if ($null -ne $existingLine) {',
'            if ($existingLine.Trim().ToLower() -eq $Line.Trim().ToLower()) {',
'                return $workingLines',
'            }',
'        }',
'    }',
'',
'    $workingLines += $Line',
'    return $workingLines',
'}',
''
)

$replacement = $replacementLines -join "`r`n"

$before = $content.Substring(0, $startIndex)
$after = $content.Substring($separatorIndex)

$newContent = $before + $replacement + $after

Set-Content -LiteralPath $targetScript -Value $newContent -Encoding UTF8

Write-Host ""
Write-Host "Finalize script fixed successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host ".\Finalize-GitHubProjectSyncProject.ps1"