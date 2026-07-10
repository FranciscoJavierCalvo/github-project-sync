#requires -version 5.1

<#
.SYNOPSIS
    Builds an optional EXE wrapper for GitHub Project Sync Manager.

.DESCRIPTION
    Uses PS2EXE, when available, to build an EXE from the latest GitHubProjectSync-GUI.ps1 script.

    The PowerShell script remains the source of truth.
    The EXE is only a generated convenience artefact.

    By default, the previous EXE with the same name is deleted before a new one is created.

.REQUIREMENTS
    - Windows PowerShell 5.1
    - GitHubProjectSync-GUI.ps1 in the repo root
    - PS2EXE available as Invoke-ps2exe or ps2exe

.EXAMPLES
    Build the EXE:
        .\Build-GitHubProjectSyncManagerExe.ps1

    Build and keep any existing EXE:
        .\Build-GitHubProjectSyncManagerExe.ps1 -KeepPrevious

    Build and open the release folder:
        .\Build-GitHubProjectSyncManagerExe.ps1 -OpenOutputFolder
#>

param(
    [string]$SourceScript = ".\GitHubProjectSync-GUI.ps1",
    [string]$OutputFolder = ".\release",
    [string]$ExeName = "GitHubProjectSyncManager.exe",
    [string]$IconPath = "",
    [string]$Version = "1.0.0.0",
    [switch]$KeepPrevious,
    [switch]$OpenOutputFolder
)

$ErrorActionPreference = "Stop"

function Test-IsBlank {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $true
    }

    if ($Value.Trim().Length -eq 0) {
        return $true
    }

    return $false
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = "INFO"
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$time] [$Level] $Message"

    if ($Level -eq "ERROR") {
        Write-Host $line -ForegroundColor Red
    }
    elseif ($Level -eq "WARN") {
        Write-Host $line -ForegroundColor Yellow
    }
    elseif ($Level -eq "OK") {
        Write-Host $line -ForegroundColor Green
    }
    else {
        Write-Host $line
    }
}

$repoRoot = (Get-Location).Path

if (-not (Test-Path -LiteralPath $SourceScript)) {
    Write-Step -Message "Source script not found: $SourceScript" -Level "ERROR"
    exit 1
}

$compilerCommand = Get-Command -Name "Invoke-ps2exe" -ErrorAction SilentlyContinue

if ($null -eq $compilerCommand) {
    $compilerCommand = Get-Command -Name "ps2exe" -ErrorAction SilentlyContinue
}

if ($null -eq $compilerCommand) {
    Write-Step -Message "PS2EXE was not found. Cannot build EXE." -Level "ERROR"
    Write-Step -Message "The PowerShell script is still the source of truth and can be run directly." -Level "WARN"
    Write-Step -Message "If allowed in your environment, install PS2EXE with:" -Level "WARN"
    Write-Host "Install-Module ps2exe -Scope CurrentUser"
    Write-Step -Message "If installation is blocked, build the EXE on another approved machine and copy only the generated EXE back if permitted." -Level "WARN"
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    Write-Step -Message "Created output folder: $OutputFolder" -Level "OK"
}

$sourceFullPath = (Resolve-Path -LiteralPath $SourceScript).Path
$outputFullPath = Join-Path -Path (Resolve-Path -LiteralPath $OutputFolder).Path -ChildPath $ExeName

Write-Step -Message "Source script: $sourceFullPath" -Level "OK"
Write-Step -Message "Output EXE: $outputFullPath" -Level "OK"
Write-Step -Message "Compiler: $($compilerCommand.Name)" -Level "OK"

if ((Test-Path -LiteralPath $outputFullPath) -and (-not $KeepPrevious)) {
    Remove-Item -LiteralPath $outputFullPath -Force
    Write-Step -Message "Deleted previous EXE: $outputFullPath" -Level "OK"
}
elseif ((Test-Path -LiteralPath $outputFullPath) -and $KeepPrevious) {
    $backupName = "GitHubProjectSyncManager_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".exe"
    $backupPath = Join-Path -Path (Resolve-Path -LiteralPath $OutputFolder).Path -ChildPath $backupName
    Copy-Item -LiteralPath $outputFullPath -Destination $backupPath -Force
    Write-Step -Message "Kept previous EXE copy: $backupPath" -Level "OK"
}

$invokeParams = @{}
$invokeParams["inputFile"] = $sourceFullPath
$invokeParams["outputFile"] = $outputFullPath
$invokeParams["noConsole"] = $true
$invokeParams["STA"] = $true
$invokeParams["title"] = "GitHub Project Sync Manager"
$invokeParams["description"] = "Safe GUI tool for managing and synchronising local GitHub projects"
$invokeParams["company"] = "Local Tool"
$invokeParams["product"] = "GitHub Project Sync Manager"
$invokeParams["version"] = $Version
$invokeParams["DPIAware"] = $true

if (-not (Test-IsBlank -Value $IconPath)) {
    if (Test-Path -LiteralPath $IconPath) {
        $invokeParams["iconFile"] = (Resolve-Path -LiteralPath $IconPath).Path
        Write-Step -Message "Using icon: $IconPath" -Level "OK"
    }
    else {
        Write-Step -Message "Icon path was provided but not found. Continuing without icon: $IconPath" -Level "WARN"
    }
}

Write-Step -Message "Building EXE. This may take a moment..." -Level "INFO"

try {
    $compilerName = $compilerCommand.Name
    & $compilerName @invokeParams
}
catch {
    Write-Step -Message "EXE build failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

if (Test-Path -LiteralPath $outputFullPath) {
    $exeItem = Get-Item -LiteralPath $outputFullPath
    Write-Step -Message "EXE build completed successfully." -Level "OK"
    Write-Step -Message "EXE path: $($exeItem.FullName)" -Level "OK"
    Write-Step -Message "EXE size: $($exeItem.Length) bytes" -Level "OK"
}
else {
    Write-Step -Message "Build command finished but EXE was not found." -Level "ERROR"
    exit 1
}

if ($OpenOutputFolder) {
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$OutputFolder`""
}

Write-Step -Message "Done." -Level "OK"
