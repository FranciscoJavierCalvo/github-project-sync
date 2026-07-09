$ErrorActionPrefer*nce = "Stop"

$ScriptPath = ".\Git*ubProjectSync-GUI.ps1"

if (-not (*est-Path -LiteralPath $ScriptPath)* {
    Write-Host "ERROR: GitHubPr*jectSync-GUI.ps1 not found in the *urrent folder." -ForegroundColor R*d
    return
}

$ResolvedPath = (R*solve-Path -LiteralPath $ScriptPat*).Path
$BackupPath = ".\GitHubProj*ctSync-GUI.ps1.phase53_before_phas*54_reporttools_$(Get-Date -Format *yyyyMMdd_HHmmss').bak"

Copy-Item *LiteralPath $ResolvedPath -Destina*ion $BackupPath -Force
Write-Host *Backup created: $BackupPath" -Fore*roundColor Yellow

$content = Get-*ontent -LiteralPath $ResolvedPath *Raw

$showDialogText = '[void]$for*.ShowDialog()'
$showDialogIndex = *content.IndexOf($showDialogText)

*f ($showDialogIndex -lt 0) {
    W*ite-Host "ERROR: Could not find Sh*wDialog line in the script." -Fore*roundColor Red
    return
}

# ---*----------------------------------*---------------------
# Insert rep*rt folder helper functions before *howDialog
# ----------------------*----------------------------------*--

if ($content.IndexOf("function*Open-ReportsFolder") -ge 0) {
    *rite-Host "Report folder helper fu*ctions already exist. Skipping fun*tion insertion." -ForegroundColor *ellow
}
else {
    $functionBlock * @'

function Open-ReportsFolder {*    Write-GuiLog -Message "Open Re*orts clicked."

    $reportsFolder*= Join-Path -Path $script:ScriptRo*t -ChildPath "reports"

    if (-n*t (Test-Path -LiteralPath $reports*older)) {
        New-Item -Path $*eportsFolder -ItemType Directory -*orce | Out-Null
        Write-GuiL*g -Message "Created reports folder* $reportsFolder"
    }

    Write-*uiLog -Message "Opening reports fo*der: $reportsFolder"

    Start-Pr*cess -FilePath "explorer.exe" -Arg*mentList "`"$reportsFolder`""

   *foreach ($status in $script:LastSt*tus) {
        Set-ProjectRunState*-ProjectName $status.Name -LastAct*on "Open Reports" -LastResult "Ope*ed"
    }

    Refresh-List
}

fun*tion Clear-ReportsFolder {
    Wri*e-GuiLog -Message "Clear Reports c*icked."

    $reportsFolder = Join*Path -Path $script:ScriptRoot -Chi*dPath "reports"

    if (-not (Tes*-Path -LiteralPath $reportsFolder)* {
        Write-GuiLog -Message "*eports folder does not exist. Noth*ng to clear."

        [void][Syst*m.Windows.Forms.MessageBox]::Show(*            "Reports folder does n*t exist yet.`r`n`r`nNothing to cle*r.",
            "Clear Reports",
*           [System.Windows.Forms.M*ssageBoxButtons]::OK,
            *System.Windows.Forms.MessageBoxIco*]::Information
        )

        *eturn
    }

    $reportFiles = Ge*-ChildItem -LiteralPath $reportsFo*der -File -ErrorAction SilentlyCon*inue | Where-Object {
        $_.N*me -like "GitHubProjectSync_Report**.txt" -or
        $_.Name -like "*itHubProjectSync_Report_*.csv" -or*        $_.Name -like "GitHubProje*tSync_Report_*.json"
    }

    $r*portCount = 0

    if ($null -ne $*eportFiles) {
        $reportCount*= @($reportFiles).Count
    }

   *if ($reportCount -eq 0) {
        *rite-GuiLog -Message "No generated*report files found to clear."

   *    [void][System.Windows.Forms.Me*sageBox]::Show(
            "No ge*erated report files were found in:*r`n`r`n$reportsFolder",
          * "Clear Reports",
            [Sys*em.Windows.Forms.MessageBoxButtons*::OK,
            [System.Windows.*orms.MessageBoxIcon]::Information
*       )

        return
    }

  * $confirmMessage = @()
    $confir*Message += "Clear generated report*files?"
    $confirmMessage += ""
*   $confirmMessage += "Folder:"
  * $confirmMessage += $reportsFolder*    $confirmMessage += ""
    $con*irmMessage += "Files to delete: $r*portCount"
    $confirmMessage += *"
    $confirmMessage += "Only the*e generated report file types will*be deleted:"
    $confirmMessage +* "- GitHubProjectSync_Report_*.txt*
    $confirmMessage += "- GitHubP*ojectSync_Report_*.csv"
    $confi*mMessage += "- GitHubProjectSync_R*port_*.json"
    $confirmMessage +* ""
    $confirmMessage += "Contin*e?"

    $answer = [System.Windows*Forms.MessageBox]::Show(
        (*confirmMessage -join "`r`n"),
    *   "Confirm Clear Reports",
      * [System.Windows.Forms.MessageBoxB*ttons]::YesNo,
        [System.Win*ows.Forms.MessageBoxIcon]::Warning*    )

    if ($answer -ne [System*Windows.Forms.DialogResult]::Yes) *
        Write-GuiLog -Message "Cl*ar Reports cancelled by user."
   *    return
    }

    $deletedCoun* = 0
    $failedCount = 0

    for*ach ($file in $reportFiles) {
    *   try {
            Remove-Item -*iteralPath $file.FullName -Force -*rrorAction Stop
            $delet*dCount++
            Write-GuiLog *Message "Deleted report file: $($f*le.FullName)"
        }
        ca*ch {
            $failedCount++
  *         Write-GuiLog -Message "Fa*led to delete report file: $($file*FullName). Error: $($_.Exception.M*ssage)" -Level "ERROR"
        }
 *  }

    foreach ($status in $scri*t:LastStatus) {
        Set-Projec*RunState -ProjectName $status.Name*-LastAction "Clear Reports" -LastResult "Deleted $deletedCount report file(s)"
    }

    Refresh-List

    $resultMessage = @()
    $resultMessage += "Clear Reports finished."
    $resultMessage += ""
    $resultMessage += "Deleted files: $deletedCount"
    $resultMessage += "Failed deletions: $failedCount"
    $resultMessage += ""
    $resultMessage += "Folder:"
    $resultMessage += $reportsFolder

    Write-GuiLog -Message "Clear Reports finished. Deleted: $deletedCount. Failed: $failedCount."

    [void][System.Windows.Forms.MessageBox]::Show(
        ($resultMessage -join "`r`n"),
        "Clear Reports",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

'@

    $before = $content.Substring(0, $showDialogIndex)
    $after = $content.Substring($showDialogIndex)

    $content = $before + $functionBlock + "`r`n" + $after

    Write-Host "Inserted report folder helper functions." -ForegroundColor Green
}

# ------------------------------------------------------------
# Update title, safety text, and phase log
# ------------------------------------------------------------

$content = $content.Replace(
    '$form.Text = "GitHub Project Sync Manager - Phase 5.3 Enhanced Reports"',
    '$form.Text = "GitHub Project Sync Manager - Phase 5.4 Reports Folder Tools"'
)

$content = $content.Replace(
    '$lblSafety.Text = "Phase 5.3 safety: Enhanced report export is read-only. Git safety rules remain unchanged."',
    '$lblSafety.Text = "Phase 5.4 safety: Reports folder tools only manage generated report files. Git safety rules remain unchanged."'
)

$content = $content.Replace(
    'Write-GuiLog -Message "Phase: 5.3 - Enhanced Reports"',
    'Write-GuiLog -Message "Phase: 5.4 - Reports Folder Tools"'
)

# ------------------------------------------------------------
# Insert Open Reports and Clear Reports buttons
# They go on the commit-message row to avoid overcrowding the main button row.
# ------------------------------------------------------------

if ($content.IndexOf('$btnOpenReports = New-Object System.Windows.Forms.Button') -ge 0) {
    Write-Host "Open Reports / Clear Reports buttons already exist. Skipping button insertion." -ForegroundColor Yellow
}
else {
    $buttonAnchor = '$chkBlockPullWithChanges = New-Object System.Windows.Forms.CheckBox'
    $buttonAnchorIndex = $content.IndexOf($buttonAnchor)

    if ($buttonAnchorIndex -lt 0) {
        Write-Host "ERROR: Could not find Block Pull checkbox anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $buttonBlock = @'

$btnOpenReports = New-Object System.Windows.Forms.Button
$btnOpenReports.Location = New-Object System.Drawing.Point(1462, 86)
$btnOpenReports.Size = New-Object System.Drawing.Size(110, 28)
$btnOpenReports.Text = "Open Reports"
$form.Controls.Add($btnOpenReports)

$btnClearReports = New-Object System.Windows.Forms.Button
$btnClearReports.Location = New-Object System.Drawing.Point(1582, 86)
$btnClearReports.Size = New-Object System.Drawing.Size(110, 28)
$btnClearReports.Text = "Clear Reports"
$form.Controls.Add($btnClearReports)

'@

    $content = $content.Insert($buttonAnchorIndex, $buttonBlock)

    Write-Host "Inserted Open Reports and Clear Reports buttons." -ForegroundColor Green
}

# ------------------------------------------------------------
# Insert event handlers before Export Report event
# ------------------------------------------------------------

if ($content.IndexOf('$btnOpenReports.Add_Click') -ge 0) {
    Write-Host "Open Reports / Clear Reports event handlers already exist. Skipping event insertion." -ForegroundColor Yellow
}
else {
    $eventAnchor = '$btnExportReport.Add_Click({'
    $eventAnchorIndex = $content.IndexOf($eventAnchor)

    if ($eventAnchorIndex -lt 0) {
        Write-Host "ERROR: Could not find Export Report event anchor." -ForegroundColor Red
        Write-Host "Backup is available here: $BackupPath" -ForegroundColor Yellow
        return
    }

    $eventBlock = @'

$btnOpenReports.Add_Click({
    Open-ReportsFolder
})

$btnClearReports.Add_Click({
    Clear-ReportsFolder
})

'@

    $content = $content.Insert($eventAnchorIndex, $eventBlock)

    Write-Host "Inserted Open Reports and Clear Reports event handlers." -ForegroundColor Green
}

# ------------------------------------------------------------
# Ensure reports are ignored
# ------------------------------------------------------------

$gitIgnorePath = ".\.gitignore"

if (Test-Path -LiteralPath $gitIgnorePath) {
    $gitIgnoreText = Get-Content -LiteralPath $gitIgnorePath -Raw

    if ($gitIgnoreText -notlike "*reports/*") {
        Add-Content -LiteralPath $gitIgnorePath -Value ""
        Add-Content -LiteralPath $gitIgnorePath -Value "# Generated reports"
        Add-Content -LiteralPath $gitIgnorePath -Value "reports/"
        Write-Host "Updated .gitignore to ignore reports folder." -ForegroundColor Green
    }
}

# ------------------------------------------------------------
# Save and validate
# ------------------------------------------------------------

Set-Content -LiteralPath $ResolvedPath -Value $content -Encoding UTF8

$updated = Get-Content -LiteralPath $ResolvedPath -Raw

$openFunctionIndex = $updated.IndexOf("function Open-ReportsFolder")
$clearFunctionIndex = $updated.IndexOf("function Clear-ReportsFolder")
$showDialogIndexAfter = $updated.IndexOf($showDialogText)
$openButtonIndex = $updated.IndexOf('$btnOpenReports = New-Object System.Windows.Forms.Button')
$clearButtonIndex = $updated.IndexOf('$btnClearReports = New-Object System.Windows.Forms.Button')
$openEventIndex = $updated.IndexOf('$btnOpenReports.Add_Click')
$clearEventIndex = $updated.IndexOf('$btnClearReports.Add_Click')

Write-Host ""
Write-Host "Validation:" -ForegroundColor Cyan
Write-Host "Open Reports function index: $openFunctionIndex"
Write-Host "Clear Reports function index: $clearFunctionIndex"
Write-Host "ShowDialog index: $showDialogIndexAfter"
Write-Host "Open Reports button index: $openButtonIndex"
Write-Host "Clear Reports button index: $clearButtonIndex"
Write-Host "Open Reports event index: $openEventIndex"
Write-Host "Clear Reports event index: $clearEventIndex"

if ($openFunctionIndex -ge 0 -and $openFunctionIndex -lt $showDialogIndexAfter) {
    Write-Host "SUCCESS: Open Reports function is before ShowDialog." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Open Reports function is not before ShowDialog." -ForegroundColor Red
    return
}

if ($clearFunctionIndex -ge 0 -and $clearFunctionIndex -lt $showDialogIndexAfter) {
    Write-Host "SUCCESS: Clear Reports function is before ShowDialog." -ForegroundColor Green
}
else {
    Write-Host "ERROR: Clear Reports function is not before ShowDialog." -ForegroundColor Red
    return
}

if ($openButtonIndex -ge 0 -and $clearButtonIndex -ge 0) {
    Write-Host "SUCCESS: Report folder buttons exist." -ForegroundColor Green
}
else {
    Write-Host "ERROR: One or more report folder buttons were not found." -ForegroundColor Red
    return
}

if ($openEventIndex -ge 0 -and $clearEventIndex -ge 0) {
    Write-Host "SUCCESS: Report folder event handlers exist." -ForegroundColor Green
}
else {
    Write-Host "ERROR: One or more report folder event handlers were not found." -ForegroundColor Red
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
Write-Host "Phase 5.4 Reports Folder Tools patch completed." -ForegroundColor Green
Write-Host ""
Write-Host "Now run:" -ForegroundColor Cyan
Write-Host ".\GitHubProjectSync-GUI.ps1" -ForegroundColor Cyan