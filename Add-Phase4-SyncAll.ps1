$ErrorActionPreference = "Stop"

$ScriptPath = ".\GitHubProjectSync-GUI.ps1"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "ERROR: GitHubProjectSync-GUI.ps1 not found in the current folder." -ForegroundColor Red
    return
}

$ResolvedPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$BackupPath = ".\GitHubProjectSync-GUI.ps1.phase41_before_phase42_syncall_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"

Copy-Item -LiteralPath $ResolvedPath -Destination $BackupPath -Force
Write-Host "Backup created: $BackupPath" -ForegroundColor Yellow

$content = Get-Content -LiteralPath $ResolvedPath -Raw

# ------------------------------------------------------------
# Insert Sync-AllProjects function before ShowDialog
# ------------------------------------------------------------

$showDialogText = '[void]$form.ShowDialog()'
$showDialogIndex = $content.IndexOf($showDialogText)

if ($showDialogIndex -lt 0) {
    Write-Host "ERROR: Could not find ShowDialog line in the script." -ForegroundColor Red
    return
}

if ($content.IndexOf("function Sync-AllProjects") -ge 0) {
    Write-Host "Sync-AllProjects function already exists. Skipping function insertion." -ForegroundColor Yellow
}
else {
    $functionBlock = @'

function Sync-AllProjects {
    Write-GuiLog -Message "Sync All clicked."

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "No projects loaded. Loading projects before Sync All."
        Load-Projects
    }

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "Sync All blocked. No projects are configured." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "No projects are configured.`r`n`r`nPlease check projects.json.",
            "Sync All",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    Write-GuiLog -Message "Refreshing project status before Sync All."
    Refresh-List

    if ($script:LastStatus.Count -eq 0) {
        Write-GuiLog -Message "Sync All blocked. No project status results are available." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "No project status results are available.`r`n`r`nClick Check Status and try again.",
            "Sync All",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $commitMessage = $script:txtCommitMessage.Text
    $safeProjects = @()
    $blockedProjects = @()
    $projectsNeedingCommit = @()

    foreach ($status in $script:LastStatus) {
        if ($status.ActionAllowed -eq "Yes") {
            $safeProjects += $status

            if ($status.ChangeCount -gt 0) {
                $projectsNeedingCommit += $status
            }
        }
        else {
            $blockedProjects += $status
        }
    }

    if ($safeProjects.Count -eq 0) {
        Write-GuiLog -Message "Sync All blocked. No safe projects are available to process." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "No safe projects are available to process.`r`n`r`nCheck the Action Allowed column.",
            "Sync All",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    if ($projectsNeedingCommit.Count -gt 0 -and (Test-IsBlank -Value $commitMessage)) {
        Write-GuiLog -Message "Sync All blocked. One or more projects have local changes, but commit message is blank." -Level "WARN"

        $messageRequired = @()
        $messageRequired += "Commit message required."
        $messageRequired += ""
        $messageRequired += "The following project(s) have local changes:"
        $messageRequired += ""

        foreach ($status in $projectsNeedingCommit) {
            $messageRequired += "- $($status.Name) ($($status.ChangeCount) change(s))"
        }

        $messageRequired += ""
        $messageRequired += "Enter a commit message before running Sync All."

        [void][System.Windows.Forms.MessageBox]::Show(
            ($messageRequired -join "`r`n"),
            "Commit message required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $summary = @()
    $summary += "Sync All Projects?"
    $summary += ""
    $summary += "Projects configured: $($script:LastStatus.Count)"
    $summary += "Safe projects to process: $($safeProjects.Count)"
    $summary += "Blocked projects to skip: $($blockedProjects.Count)"
    $summary += "Projects needing commit: $($projectsNeedingCommit.Count)"
    $summary += ""
    $summary += "Processing behaviour:"
    $summary += "- Process safe projects one by one"
    $summary += "- Skip blocked or unsafe projects"
    $summary += "- Stop on first failure"
    $summary += "- Commit local changes only when needed"
    $summary += "- Pull using git pull --ff-only"
    $summary += "- Push current branch to origin"
    $summary += ""
    $summary += "Safety rules:"
    $summary += "- No force push"
    $summary += "- No reset hard"
    $summary += "- No git clean"
    $summary += "- No branch switching"
    $summary += "- No automatic conflict resolution"
    $summary += "- Do not push if pull fails"
    $summary += ""
    $summary += "Projects to process:"
    $summary += ""

    $projectNumber = 1

    foreach ($status in $safeProjects) {
        if ($status.ChangeCount -gt 0) {
            $plannedAction = "Commit, pull --ff-only, push"
        }
        else {
            $plannedAction = "Pull --ff-only, push"
        }

        $summary += "$projectNumber. $($status.Name)"
        $summary += "   Branch: $($status.CurrentBranch)"
        $summary += "   Local status: $($status.LocalStatus)"
        $summary += "   Changes: $($status.ChangeCount)"
        $summary += "   Planned action: $plannedAction"
        $summary += ""

        $projectNumber++
    }

    if ($blockedProjects.Count -gt 0) {
        $summary += "Blocked projects to skip:"
        $summary += ""

        foreach ($status in $blockedProjects) {
            $summary += "- $($status.Name): $($status.ActionAllowed)"
        }

        $summary += ""
    }

    $summary += "Continue?"

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ($summary -join "`r`n"),
        "Confirm Sync All",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-GuiLog -Message "Sync All cancelled by user."
        return
    }

    $results = @()
    $processedCount = 0
    $successCount = 0
    $failedCount = 0
    $skippedCount = $blockedProjects.Count

    foreach ($status in $safeProjects) {
        $processedCount++

        Write-GuiLog -Message "Sync All processing project $processedCount of $($safeProjects.Count): $($status.Name)"

        if (-not (Test-SelectedProjectSafeForWrite -Status $status -ActionName "Sync All")) {
            $results += "SKIPPED: $($status.Name) - safety validation failed"
            $skippedCount++
            continue
        }

        $branchName = $status.CurrentBranch
        $projectFailed = $false

        if ($status.ChangeCount -gt 0) {
            Write-GuiLog -Message "Sync All step: checking local changes for $($status.Name)."

            $statusResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "status --porcelain" -LogCommand $true

            if (-not $statusResult.Success) {
                Write-GuiLog -Message "Sync All failed. Could not check local status for $($status.Name)." -Level "ERROR"
                $results += "FAILED: $($status.Name) - could not check local status"
                $failedCount++
                $projectFailed = $true
            }

            if (-not $projectFailed -and -not (Test-IsBlank -Value $statusResult.StdOut)) {
                Write-GuiLog -Message "Sync All step: staging local changes for $($status.Name)."

                $addResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "add ." -LogCommand $true

                if (-not $addResult.Success) {
                    Write-GuiLog -Message "Sync All failed. git add failed for $($status.Name)." -Level "ERROR"
                    $results += "FAILED: $($status.Name) - git add failed"
                    $failedCount++
                    $projectFailed = $true
                }

                if (-not $projectFailed) {
                    Write-GuiLog -Message "Sync All step: committing local changes for $($status.Name)."

                    $safeMessage = Escape-GitMessage -Message $commitMessage
                    $commitResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "commit -m `"$safeMessage`"" -LogCommand $true

                    if (-not $commitResult.Success) {
                        Write-GuiLog -Message "Sync All failed. git commit failed for $($status.Name)." -Level "ERROR"
                        $results += "FAILED: $($status.Name) - git commit failed"
                        $failedCount++
                        $projectFailed = $true
                    }
                    else {
                        Write-GuiLog -Message "Commit completed for $($status.Name)."
                    }
                }
            }
            elseif (-not $projectFailed) {
                Write-GuiLog -Message "No local changes detected at runtime for $($status.Name). Commit step skipped."
            }
        }
        else {
            Write-GuiLog -Message "No local changes detected for $($status.Name). Commit step skipped."
        }

        if (-not $projectFailed) {
            Write-GuiLog -Message "Sync All step: pulling latest changes for $($status.Name)."

            $pullResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "pull --ff-only origin $branchName" -LogCommand $true

            if (-not $pullResult.Success) {
                Write-GuiLog -Message "Sync All failed. Pull failed for $($status.Name). Push was not attempted." -Level "ERROR"
                $results += "FAILED: $($status.Name) - pull failed, push not attempted"
                $failedCount++
                $projectFailed = $true
            }
            else {
                Write-GuiLog -Message "Pull completed for $($status.Name)."
            }
        }

        if (-not $projectFailed) {
            Write-GuiLog -Message "Sync All step: pushing branch for $($status.Name)."

            $pushResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "push origin $branchName" -LogCommand $true

            if (-not $pushResult.Success) {
                Write-GuiLog -Message "Sync All failed. Push failed for $($status.Name)." -Level "ERROR"
                $results += "FAILED: $($status.Name) - push failed"
                $failedCount++
                $projectFailed = $true
            }
            else {
                Write-GuiLog -Message "Push completed for $($status.Name)."
            }
        }

        if ($projectFailed) {
            Write-GuiLog -Message "Sync All stopping on first failure." -Level "ERROR"
            break
        }
        else {
            $successCount++
            $results += "SUCCESS: $($status.Name)"
        }
    }

    Write-GuiLog -Message "Sync All completed. Refreshing project status."
    Refresh-List

    $finalSummary = @()
    $finalSummary += "Sync All finished."
    $finalSummary += ""
    $finalSummary += "Successful projects: $successCount"
    $finalSummary += "Failed projects: $failedCount"
    $finalSummary += "Skipped projects: $skippedCount"
    $finalSummary += ""
    $finalSummary += "Results:"
    $finalSummary += ""

    foreach ($line in $results) {
        $finalSummary += "- $line"
    }

    if ($blockedProjects.Count -gt 0) {
        $finalSummary += ""
        $finalSummary += "Initially blocked projects:"
        foreach ($status in $blockedProjects) {
            $finalSummary += "- $($status.Name): $($status.ActionAllowed)"
        }
    }

    Write-GuiLog -Message "Sync All final summary:`r`n$($finalSummary -join "`r`n")"

    if ($failedCount -gt 0) {
        $icon = [System.Windows.Forms.MessageBoxIcon]::Error
        $title = "Sync All finished with errors"
    }
    else {
        $icon = [System.Windows.Forms.MessageBoxIcon]::Information
        $title = "Sync All complete"
    }

    [void][System.Windows.Forms.MessageBox]::Show(
        ($finalSummary -join "`r`n"),
        $title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    )
}

'@

    $before = $content.Substring(0, $showDialogIndex)
    $after = $content.Substring($showDialogIndex)
    $content = $before + $functionBlock + "`r`n" + $after

    Write-Host "Inserted Sync-AllProjects function." -ForegroundColor Green
}

# ------------------------------------------------------------
# Update title and safety text
# ------------------------------------------------------------

$content = $content.Replace(
    '$form.Text = "GitHub Project Sync Manager - Phase 4.1 Preview Sync All"',
    '$form.Text = "GitHub Project Sync Manager - Phase 4.2 Sync All"'
)

$content = $content.Replace(
    '$lblSafety.Text = "Phase 4.1 safety: Preview Sync All is dry-run only. No commit, pull, push, reset, clean, branch switching, or automatic conflict resolution."',
    '$lblSafety.Text = "Phase 4.2 safety: Sync All processes safe projects one by one. No force push, reset hard, clean, branch switching, or automatic conflict resolution."'
)

$content = $content.Replace(
    'Write-GuiLog -Message "Phase: 4.1 - Preview Sync All"',
    'Write-GuiLog -Message "Phase: 4.2 - Sync All"'
)

# ------------------------------------------------------------
# Insert Sync All button after Preview Sync All button
# ------------------------------------------------------------

if ($content.IndexOf('$btnSyncAll = New-Object System.Windows.Forms.Button') -ge 0) {
    Write-Host "Sync All button already exists. Skipping button insertion." -ForegroundColor Yellow
}
else {
    $buttonAnchor = '$form.Controls.Add($btnPreviewSyncAll)'
    $buttonAnchorIndex = $content.IndexOf($buttonAnchor)

    if ($buttonAnchorIndex -lt 0) {
        Write-Host "ERROR: Could not find form.Controls.Add(btnPreviewSyncAll) anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $buttonInsertIndex = $buttonAnchorIndex + $buttonAnchor.Length

    $syncAllButtonBlock = @'

$btnSyncAll = New-Object System.Windows.Forms.Button
$btnSyncAll.Location = New-Object System.Drawing.Point(942, 45)
$btnSyncAll.Size = New-Object System.Drawing.Size(120, 32)
$btnSyncAll.Text = "Sync All"
$form.Controls.Add($btnSyncAll)
'@

    $content = $content.Insert($buttonInsertIndex, $syncAllButtonBlock)
    Write-Host "Inserted Sync All button." -ForegroundColor Green
}

# Make a bit more horizontal room and shift existing utility buttons.
$content = $content.Replace(
    '$form.Size = New-Object System.Drawing.Size(1480, 880)',
    '$form.Size = New-Object System.Drawing.Size(1680, 880)'
)

$content = $content.Replace(
    '$form.MinimumSize = New-Object System.Drawing.Size(1250, 760)',
    '$form.MinimumSize = New-Object System.Drawing.Size(1450, 760)'
)

$content = $content.Replace(
    '$txtConfigPath.Size = New-Object System.Drawing.Size(1000, 24)',
    '$txtConfigPath.Size = New-Object System.Drawing.Size(1180, 24)'
)

$content = $content.Replace(
    '$btnCreateSample.Location = New-Object System.Drawing.Point(1145, 8)',
    '$btnCreateSample.Location = New-Object System.Drawing.Point(1330, 8)'
)

$content = $content.Replace(
    '$btnExit.Location = New-Object System.Drawing.Point(1275, 8)',
    '$btnExit.Location = New-Object System.Drawing.Point(1460, 8)'
)

$content = $content.Replace(
    '$btnOpenFolder.Location = New-Object System.Drawing.Point(942, 45)',
    '$btnOpenFolder.Location = New-Object System.Drawing.Point(1072, 45)'
)

$content = $content.Replace(
    '$btnOpenRepo.Location = New-Object System.Drawing.Point(1072, 45)',
    '$btnOpenRepo.Location = New-Object System.Drawing.Point(1202, 45)'
)

$content = $content.Replace(
    '$btnDetails.Location = New-Object System.Drawing.Point(1222, 45)',
    '$btnDetails.Location = New-Object System.Drawing.Point(1352, 45)'
)

$content = $content.Replace(
    '$btnClearLog.Location = New-Object System.Drawing.Point(1332, 45)',
    '$btnClearLog.Location = New-Object System.Drawing.Point(1462, 45)'
)

$content = $content.Replace(
    '$lvProjects.Size = New-Object System.Drawing.Size(1435, 420)',
    '$lvProjects.Size = New-Object System.Drawing.Size(1635, 420)'
)

$content = $content.Replace(
    '$txtLog.Size = New-Object System.Drawing.Size(1435, 220)',
    '$txtLog.Size = New-Object System.Drawing.Size(1635, 220)'
)

# ------------------------------------------------------------
# Insert Sync All event handler
# ------------------------------------------------------------

if ($content.IndexOf('$btnSyncAll.Add_Click') -ge 0) {
    Write-Host "Sync All event handler already exists. Skipping event insertion." -ForegroundColor Yellow
}
else {
    $eventAnchor = '$btnPreviewSyncAll.Add_Click({'
    $eventStart = $content.IndexOf($eventAnchor)

    if ($eventStart -lt 0) {
        Write-Host "ERROR: Could not find btnPreviewSyncAll Add_Click event anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $eventEnd = $content.IndexOf('})', $eventStart)

    if ($eventEnd -lt 0) {
        Write-Host "ERROR: Could not find end of btnPreviewSyncAll Add_Click event." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $eventInsertIndex = $eventEnd + 2

    $syncAllEventBlock = @'

$btnSyncAll.Add_Click({
    Sync-AllProjects
})
'@

    $content = $content.Insert($eventInsertIndex, $syncAllEventBlock)
    Write-Host "Inserted Sync All event handler." -ForegroundColor Green
}

# ------------------------------------------------------------
# Save and validate
# ------------------------------------------------------------

Set-Content -LiteralPath $ResolvedPath -Value $content -Encoding UTF8

$updated = Get-Content -LiteralPath $ResolvedPath -Raw

$functionIndex = $updated.IndexOf("function Sync-AllProjects")
$showDialogIndexAfter = $updated.IndexOf($showDialogText)
$buttonIndex = $updated.IndexOf('$btnSyncAll = New-Object System.Windows.Forms.Button')
$eventIndex = $updated.IndexOf('$btnSyncAll.Add_Click')

Write-Host ""
Write-Host "Validation:" -ForegroundColor Cyan
Write-Host "Sync All function index: $functionIndex"
Write-Host "ShowDialog index: $showDialogIndexAfter"
Write-Host "Sync All button index: $buttonIndex"
Write-Host "Sync All event index: $eventIndex"

if ($functionIndex -ge 0 -and $functionIndex -lt $showDialogIndexAfter) {
    Write-Host "SUCCESS: Sync All function is before ShowDialog." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Sync All function is not before ShowDialog." -ForegroundColor Red
    return
}

if ($buttonIndex -ge 0) {
    Write-Host "SUCCESS: Sync All button exists." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Sync All button was not found." -ForegroundColor Red
    return
}

if ($eventIndex -ge 0) {
    Write-Host "SUCCESS: Sync All event handler exists." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Sync All event handler was not found." -ForegroundColor Red
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
Write-Host "Phase 4.2 Sync All patch completed." -ForegroundColor Green
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host ".\GitHubProjectSync-GUI.ps1" -ForegroundColor Cyan