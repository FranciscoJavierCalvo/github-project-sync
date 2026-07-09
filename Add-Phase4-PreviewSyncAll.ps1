$ErrorActionPreference = "Stop"

$ScriptPath = ".\GitHubProjectSync-GUI.ps1"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "ERROR: GitHubProjectSync-GUI.ps1 not found in the current folder." -ForegroundColor Red
    return
}

$ResolvedPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$BackupPath = ".\GitHubProjectSync-GUI.ps1.phase3_before_phase4_preview_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"

Copy-Item -LiteralPath $ResolvedPath -Destination $BackupPath -Force
Write-Host "Backup created: $BackupPath" -ForegroundColor Yellow

$content = Get-Content -LiteralPath $ResolvedPath -Raw

# ------------------------------------------------------------
# Insert Preview-SyncAllProjects function before ShowDialog
# ------------------------------------------------------------

$showDialogText = '[void]$form.ShowDialog()'
$showDialogIndex = $content.IndexOf($showDialogText)

if ($showDialogIndex -lt 0) {
    Write-Host "ERROR: Could not find ShowDialog line in the script." -ForegroundColor Red
    return
}

if ($content.IndexOf("function Preview-SyncAllProjects") -ge 0) {
    Write-Host "Preview-SyncAllProjects function already exists. Skipping function insertion." -ForegroundColor Yellow
}
else {
    $functionBlock = @'

function Preview-SyncAllProjects {
    Write-GuiLog -Message "Preview Sync All clicked."

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "No projects loaded. Loading projects before preview."
        Load-Projects
    }

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "Preview Sync All blocked. No projects are configured." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "No projects are configured.`r`n`r`nPlease check projects.json.",
            "Preview Sync All",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    Write-GuiLog -Message "Refreshing project status before Preview Sync All."
    Refresh-List

    if ($script:LastStatus.Count -eq 0) {
        Write-GuiLog -Message "Preview Sync All blocked. No project status results are available." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "No project status results are available.`r`n`r`nClick Check Status and try again.",
            "Preview Sync All",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $summary = @()
    $summary += "Preview Sync All"
    $summary += ""
    $summary += "This is a dry-run preview only."
    $summary += "No commit, pull, push, reset, clean, checkout, merge, or rebase commands will be executed."
    $summary += ""
    $summary += "Projects found: $($script:LastStatus.Count)"
    $summary += ""

    $projectNumber = 1
    $safeCount = 0
    $blockedCount = 0
    $modifiedCount = 0
    $cleanCount = 0

    foreach ($status in $script:LastStatus) {
        $plannedAction = ""

        if ($status.ActionAllowed -ne "Yes") {
            $plannedAction = "Skip - action is not allowed"
            $blockedCount++
        }
        elseif ($status.ChangeCount -gt 0) {
            $plannedAction = "Would require commit message, then pull --ff-only, then push"
            $safeCount++
            $modifiedCount++
        }
        else {
            $plannedAction = "Would pull --ff-only, then push"
            $safeCount++
            $cleanCount++
        }

        $summary += "$projectNumber. $($status.Name)"
        $summary += "   Path: $($status.LocalPath)"
        $summary += "   Branch: $($status.CurrentBranch)"
        $summary += "   Local status: $($status.LocalStatus)"
        $summary += "   Changes: $($status.ChangeCount)"
        $summary += "   Remote match: $($status.RemoteMatch)"
        $summary += "   Action allowed: $($status.ActionAllowed)"
        $summary += "   Planned action: $plannedAction"
        $summary += ""

        $projectNumber++
    }

    $summary += "Summary"
    $summary += "Safe projects: $safeCount"
    $summary += "Blocked projects: $blockedCount"
    $summary += "Clean projects: $cleanCount"
    $summary += "Projects with local changes: $modifiedCount"
    $summary += ""
    $summary += "Phase 4.1 is preview only. Real Sync All will be implemented later in Phase 4.2."

    $summaryText = $summary -join "`r`n"

    Write-GuiLog -Message "Preview Sync All summary:`r`n$summaryText"

    [void][System.Windows.Forms.MessageBox]::Show(
        $summaryText,
        "Preview Sync All",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

'@

    $before = $content.Substring(0, $showDialogIndex)
    $after = $content.Substring($showDialogIndex)
    $content = $before + $functionBlock + "`r`n" + $after

    Write-Host "Inserted Preview-SyncAllProjects function." -ForegroundColor Green
}

# ------------------------------------------------------------
# Update title and safety text
# ------------------------------------------------------------

$content = $content.Replace(
    '$form.Text = "GitHub Project Sync Manager - Phase 3 Sync Selected"',
    '$form.Text = "GitHub Project Sync Manager - Phase 4.1 Preview Sync All"'
)

$content = $content.Replace(
    '$lblSafety.Text = "Phase 3 safety: selected-project sync only. No force push, reset hard, clean, branch switching, or automatic conflict resolution."',
    '$lblSafety.Text = "Phase 4.1 safety: Preview Sync All is dry-run only. No commit, pull, push, reset, clean, branch switching, or automatic conflict resolution."'
)

$content = $content.Replace(
    'Write-GuiLog -Message "Phase: 3 - Sync Selected"',
    'Write-GuiLog -Message "Phase: 4.1 - Preview Sync All"'
)

# ------------------------------------------------------------
# Insert Preview Sync All button after Sync Selected button
# ------------------------------------------------------------

if ($content.IndexOf('$btnPreviewSyncAll = New-Object System.Windows.Forms.Button') -ge 0) {
    Write-Host "Preview Sync All button already exists. Skipping button insertion." -ForegroundColor Yellow
}
else {
    $buttonAnchor = '$form.Controls.Add($btnSync)'
    $buttonAnchorIndex = $content.IndexOf($buttonAnchor)

    if ($buttonAnchorIndex -lt 0) {
        Write-Host "ERROR: Could not find form.Controls.Add(btnSync) anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $buttonInsertIndex = $buttonAnchorIndex + $buttonAnchor.Length

    $previewButtonBlock = @'

$btnPreviewSyncAll = New-Object System.Windows.Forms.Button
$btnPreviewSyncAll.Location = New-Object System.Drawing.Point(792, 45)
$btnPreviewSyncAll.Size = New-Object System.Drawing.Size(140, 32)
$btnPreviewSyncAll.Text = "Preview Sync All"
$form.Controls.Add($btnPreviewSyncAll)
'@

    $content = $content.Insert($buttonInsertIndex, $previewButtonBlock)
    Write-Host "Inserted Preview Sync All button." -ForegroundColor Green
}

# Move existing buttons right to make space.
$content = $content.Replace(
    '$btnOpenFolder.Location = New-Object System.Drawing.Point(792, 45)',
    '$btnOpenFolder.Location = New-Object System.Drawing.Point(942, 45)'
)

$content = $content.Replace(
    '$btnOpenRepo.Location = New-Object System.Drawing.Point(922, 45)',
    '$btnOpenRepo.Location = New-Object System.Drawing.Point(1072, 45)'
)

$content = $content.Replace(
    '$btnDetails.Location = New-Object System.Drawing.Point(1072, 45)',
    '$btnDetails.Location = New-Object System.Drawing.Point(1222, 45)'
)

$content = $content.Replace(
    '$btnClearLog.Location = New-Object System.Drawing.Point(1182, 45)',
    '$btnClearLog.Location = New-Object System.Drawing.Point(1332, 45)'
)

# ------------------------------------------------------------
# Insert Preview Sync All event handler
# ------------------------------------------------------------

if ($content.IndexOf('$btnPreviewSyncAll.Add_Click') -ge 0) {
    Write-Host "Preview Sync All event handler already exists. Skipping event insertion." -ForegroundColor Yellow
}
else {
    $eventAnchor = '$btnSync.Add_Click({'
    $eventStart = $content.IndexOf($eventAnchor)

    if ($eventStart -lt 0) {
        Write-Host "ERROR: Could not find btnSync Add_Click event anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $eventEnd = $content.IndexOf('})', $eventStart)

    if ($eventEnd -lt 0) {
        Write-Host "ERROR: Could not find end of btnSync Add_Click event." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $eventInsertIndex = $eventEnd + 2

    $previewEventBlock = @'

$btnPreviewSyncAll.Add_Click({
    Preview-SyncAllProjects
})
'@

    $content = $content.Insert($eventInsertIndex, $previewEventBlock)
    Write-Host "Inserted Preview Sync All event handler." -ForegroundColor Green
}

# ------------------------------------------------------------
# Save and validate
# ------------------------------------------------------------

Set-Content -LiteralPath $ResolvedPath -Value $content -Encoding UTF8

$updated = Get-Content -LiteralPath $ResolvedPath -Raw

$functionIndex = $updated.IndexOf("function Preview-SyncAllProjects")
$showDialogIndexAfter = $updated.IndexOf($showDialogText)
$buttonIndex = $updated.IndexOf('$btnPreviewSyncAll = New-Object System.Windows.Forms.Button')
$eventIndex = $updated.IndexOf('$btnPreviewSyncAll.Add_Click')

Write-Host ""
Write-Host "Validation:" -ForegroundColor Cyan
Write-Host "Preview function index: $functionIndex"
Write-Host "ShowDialog index: $showDialogIndexAfter"
Write-Host "Preview button index: $buttonIndex"
Write-Host "Preview event index: $eventIndex"

if ($functionIndex -ge 0 -and $functionIndex -lt $showDialogIndexAfter) {
    Write-Host "SUCCESS: Preview function is before ShowDialog." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Preview function is not before ShowDialog." -ForegroundColor Red
    return
}

if ($buttonIndex -ge 0) {
    Write-Host "SUCCESS: Preview button exists." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Preview button was not found." -ForegroundColor Red
    return
}

if ($eventIndex -ge 0) {
    Write-Host "SUCCESS: Preview event handler exists." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Preview event handler was not found." -ForegroundColor Red
    return
}

$tokens = $null
$errors = $null

[System.Management.Automation.Language.Parser]::ParseFile(
    $ResolvedPath,
    [ref]$tokens,
    [ref]$errors
) | Out-Null

if ($errors.Count -eq 0) {
    Write-Host "SUCCESS: Parser check passed." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Parser errors found:" -ForegroundColor Red

    foreach ($err in $errors) {
        Write-Host "Line $($err.Extent.StartLineNumber), Column $($err.Extent.StartColumnNumber): $($err.Message)" -ForegroundColor Red
        Write-Host "Code: $($err.Extent.Text)" -ForegroundColor Yellow
    }

    return
}

Write-Host ""
Write-Host "Phase 4.1 Preview Sync All patch completed." -ForegroundColor Green
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host ".\GitHubProjectSync-GUI.ps1" -ForegroundColor Cyan