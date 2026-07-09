#requires -version 5.1

<#
.SYNOPSIS
    GitHub Project Sync Manager - Phase 2

.DESCRIPTION
    PowerShell Windows Forms GUI for checking and safely managing multiple local GitHub project folders.

    Phase 2 adds selected-project manual actions:
    - Pull Selected
    - Commit Selected
    - Push Selected

    Safety rules:
    - No force push
    - No reset hard
    - No git clean
    - No automatic conflict resolution
    - Remote mismatch blocks write actions
    - Detached HEAD blocks write actions
    - Merge conflicts block write actions
    - Commit message required for commit
    - Push confirmation enabled by default
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------
# Global settings
# ------------------------------------------------------------

if ($null -eq $PSScriptRoot -or $PSScriptRoot.Trim().Length -eq 0) {
    $script:ScriptRoot = (Get-Location).Path
}
else {
    $script:ScriptRoot = $PSScriptRoot
}

$script:ConfigPath = Join-Path -Path $script:ScriptRoot -ChildPath "projects.json"
$script:LogFolder = Join-Path -Path $script:ScriptRoot -ChildPath "logs"
$script:Projects = @()
$script:LastStatus = @()
$script:GitAvailable = $false
$script:LogFile = $null

# GUI globals
$script:form = $null
$script:lvProjects = $null
$script:txtLog = $null
$script:txtCommitMessage = $null
$script:chkConfirmPush = $null
$script:chkBlockPullWithChanges = $null

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

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

function Initialize-Log {
    if (-not (Test-Path -LiteralPath $script:LogFolder)) {
        New-Item -Path $script:LogFolder -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path -Path $script:LogFolder -ChildPath "GitHubProjectSync_$timestamp.log"

    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
}

function Write-GuiLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = "INFO"
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$time] [$Level] $Message"

    if ($null -ne $script:txtLog) {
        $script:txtLog.AppendText($line + "`r`n")
    }

    if (-not (Test-IsBlank -Value $script:LogFile)) {
        Add-Content -Path $script:LogFile -Value $line
    }
}

function Test-GitInstalled {
    try {
        $cmd = Get-Command -Name "git.exe" -ErrorAction SilentlyContinue

        if ($null -eq $cmd) {
            $cmd = Get-Command -Name "git" -ErrorAction SilentlyContinue
        }

        if ($null -eq $cmd) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

function Escape-GitMessage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if ($null -eq $Message) {
        return ""
    }

    $escaped = $Message.Replace("\", "\\")
    $escaped = $escaped.Replace('"', '\"')

    return $escaped
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Arguments,

        [bool]$LogCommand = $true
    )

    $result = New-Object PSObject -Property @{
        Success = $false
        ExitCode = 999
        StdOut = ""
        StdErr = ""
        Command = "git $Arguments"
    }

    try {
        if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
            $result.StdErr = "Working directory does not exist: $WorkingDirectory"
            return $result
        }

        if ($LogCommand) {
            Write-GuiLog -Message "Running in: $WorkingDirectory"
            Write-GuiLog -Message "Command: git $Arguments"
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "git.exe"
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        [void]$process.Start()

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        $process.WaitForExit()

        $result.ExitCode = $process.ExitCode
        $result.StdOut = $stdout.Trim()
        $result.StdErr = $stderr.Trim()

        if ($process.ExitCode -eq 0) {
            $result.Success = $true
        }

        if ($LogCommand) {
            Write-GuiLog -Message "Exit code: $($result.ExitCode)"

            if (-not (Test-IsBlank -Value $result.StdOut)) {
                Write-GuiLog -Message "STDOUT:`r`n$($result.StdOut)"
            }

            if (-not (Test-IsBlank -Value $result.StdErr)) {
                Write-GuiLog -Message "STDERR:`r`n$($result.StdErr)" -Level "WARN"
            }
        }
    }
    catch {
        $result.StdErr = $_.Exception.Message

        if ($LogCommand) {
            Write-GuiLog -Message "Command failed: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    return $result
}

function Normalize-RepoUrl {
    param(
        [AllowNull()]
        [string]$RepoUrl
    )

    if (Test-IsBlank -Value $RepoUrl) {
        return ""
    }

    $value = $RepoUrl.Trim()
    $value = $value.Replace("\", "/")

    if ($value -match "^git@([^:]+):(.+)$") {
        $hostName = $matches[1]
        $repoPath = $matches[2]
        $value = "https://$hostName/$repoPath"
    }

    while ($value.EndsWith("/")) {
        $value = $value.Substring(0, $value.Length - 1)
    }

    if ($value.ToLower().EndsWith(".git")) {
        $value = $value.Substring(0, $value.Length - 4)
    }

    return $value.ToLower()
}

function ConvertTo-WebRepoUrl {
    param(
        [AllowNull()]
        [string]$RepoUrl
    )

    if (Test-IsBlank -Value $RepoUrl) {
        return ""
    }

    $value = $RepoUrl.Trim()
    $value = $value.Replace("\", "/")

    if ($value -match "^git@([^:]+):(.+)$") {
        $hostName = $matches[1]
        $repoPath = $matches[2]
        $value = "https://$hostName/$repoPath"
    }

    while ($value.EndsWith("/")) {
        $value = $value.Substring(0, $value.Length - 1)
    }

    if ($value.ToLower().EndsWith(".git")) {
        $value = $value.Substring(0, $value.Length - 4)
    }

    return $value
}

function Create-SampleConfig {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        Write-GuiLog -Message "Config already exists: $script:ConfigPath"
        return
    }

    $sample = @(
        "[",
        "  {",
        '    "Name": "Example Project",',
        '    "LocalPath": "C:\\Path\\To\\ExampleProject",',
        '    "RepoUrl": "https://github.com/YourUser/example-project.git",',
        '    "DefaultBranch": "main"',
        "  }",
        "]"
    )

    Set-Content -Path $script:ConfigPath -Value $sample -Encoding UTF8

    Write-GuiLog -Message "Created sample config: $script:ConfigPath" -Level "WARN"
}

function Load-Projects {
    $script:Projects = @()

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Write-GuiLog -Message "Config file not found: $script:ConfigPath" -Level "WARN"
        return
    }

    try {
        $json = Get-Content -Path $script:ConfigPath -Raw -ErrorAction Stop

        if (Test-IsBlank -Value $json) {
            Write-GuiLog -Message "Config file is empty." -Level "ERROR"
            return
        }

        $loaded = $json | ConvertFrom-Json -ErrorAction Stop

        foreach ($project in @($loaded)) {
            $name = ""
            $localPath = ""
            $repoUrl = ""
            $defaultBranch = ""

            if ($null -ne $project.Name) {
                $name = [string]$project.Name
            }

            if ($null -ne $project.LocalPath) {
                $localPath = [string]$project.LocalPath
            }

            if ($null -ne $project.RepoUrl) {
                $repoUrl = [string]$project.RepoUrl
            }

            if ($null -ne $project.DefaultBranch) {
                $defaultBranch = [string]$project.DefaultBranch
            }

            if (Test-IsBlank -Value $name) {
                if (-not (Test-IsBlank -Value $localPath)) {
                    $name = Split-Path -Path $localPath -Leaf
                }
                else {
                    $name = "Unnamed Project"
                }
            }

            if (Test-IsBlank -Value $defaultBranch) {
                $defaultBranch = "main"
            }

            $obj = New-Object PSObject -Property @{
                Name = $name
                LocalPath = $localPath
                RepoUrl = $repoUrl
                DefaultBranch = $defaultBranch
            }

            $script:Projects += $obj
        }

        Write-GuiLog -Message "Loaded $($script:Projects.Count) project(s)."
    }
    catch {
        Write-GuiLog -Message "Failed to load projects.json: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Test-MergeConflict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $conflicts = Invoke-GitCommand -WorkingDirectory $WorkingDirectory -Arguments "diff --name-only --diff-filter=U" -LogCommand $false

    if (-not $conflicts.Success) {
        return $true
    }

    if (-not (Test-IsBlank -Value $conflicts.StdOut)) {
        return $true
    }

    return $false
}

function Get-ProjectStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Project
    )

    $status = New-Object PSObject -Property @{
        Name = $Project.Name
        LocalPath = $Project.LocalPath
        ConfigRepoUrl = $Project.RepoUrl
        DefaultBranch = $Project.DefaultBranch
        FolderStatus = "Unknown"
        GitRepoStatus = "Unknown"
        CurrentBranch = ""
        RemoteUrl = ""
        RemoteMatch = "Unknown"
        LocalStatus = "Unknown"
        ChangeCount = 0
        AheadBehind = ""
        HasConflicts = $false
        ActionAllowed = "Unknown"
        Message = ""
    }

    if (Test-IsBlank -Value $Project.LocalPath) {
        $status.FolderStatus = "Missing Path"
        $status.GitRepoStatus = "Skipped"
        $status.LocalStatus = "Error"
        $status.ActionAllowed = "No - Missing Path"
        $status.Message = "LocalPath is empty."
        return $status
    }

    if (-not (Test-Path -LiteralPath $Project.LocalPath)) {
        $status.FolderStatus = "Missing"
        $status.GitRepoStatus = "Skipped"
        $status.LocalStatus = "Error"
        $status.ActionAllowed = "No - Folder Missing"
        $status.Message = "Folder does not exist."
        return $status
    }

    $status.FolderStatus = "OK"

    if (-not $script:GitAvailable) {
        $status.GitRepoStatus = "Skipped"
        $status.LocalStatus = "Error"
        $status.ActionAllowed = "No - Git Missing"
        $status.Message = "Git is not available in PATH."
        return $status
    }

    $inside = Invoke-GitCommand -WorkingDirectory $Project.LocalPath -Arguments "rev-parse --is-inside-work-tree" -LogCommand $false

    if (-not $inside.Success) {
        $status.GitRepoStatus = "Not Git Repo"
        $status.LocalStatus = "Error"
        $status.ActionAllowed = "No - Not Git Repo"
        $status.Message = $inside.StdErr
        return $status
    }

    if ($inside.StdOut -ne "true") {
        $status.GitRepoStatus = "Not Git Repo"
        $status.LocalStatus = "Error"
        $status.ActionAllowed = "No - Not Git Repo"
        $status.Message = "Folder is not a Git working tree."
        return $status
    }

    $status.GitRepoStatus = "OK"

    $branch = Invoke-GitCommand -WorkingDirectory $Project.LocalPath -Arguments "rev-parse --abbrev-ref HEAD" -LogCommand $false

    if ($branch.Success) {
        $status.CurrentBranch = $branch.StdOut
    }
    else {
        $status.CurrentBranch = "Unknown"
    }

    $remote = Invoke-GitCommand -WorkingDirectory $Project.LocalPath -Arguments "remote get-url origin" -LogCommand $false

    if ($remote.Success) {
        $status.RemoteUrl = $remote.StdOut
    }
    else {
        $status.RemoteUrl = ""
    }

    $configuredRemote = Normalize-RepoUrl -RepoUrl $Project.RepoUrl
    $actualRemote = Normalize-RepoUrl -RepoUrl $status.RemoteUrl

    if ((Test-IsBlank -Value $configuredRemote) -and (Test-IsBlank -Value $actualRemote)) {
        $status.RemoteMatch = "No Remote"
    }
    elseif (Test-IsBlank -Value $configuredRemote) {
        $status.RemoteMatch = "No Config"
    }
    elseif (Test-IsBlank -Value $actualRemote) {
        $status.RemoteMatch = "Missing Origin"
    }
    elseif ($configuredRemote -eq $actualRemote) {
        $status.RemoteMatch = "Yes"
    }
    else {
        $status.RemoteMatch = "No"
    }

    $porcelain = Invoke-GitCommand -WorkingDirectory $Project.LocalPath -Arguments "status --porcelain" -LogCommand $false

    if ($porcelain.Success) {
        if (Test-IsBlank -Value $porcelain.StdOut) {
            $status.LocalStatus = "Clean"
            $status.ChangeCount = 0
        }
        else {
            $lines = $porcelain.StdOut -split "`r?`n"
            $count = 0

            foreach ($line in $lines) {
                if (-not (Test-IsBlank -Value $line)) {
                    $count++
                }
            }

            $status.LocalStatus = "Modified"
            $status.ChangeCount = $count
        }
    }
    else {
        $status.LocalStatus = "Error"
        $status.Message = $porcelain.StdErr
    }

    $short = Invoke-GitCommand -WorkingDirectory $Project.LocalPath -Arguments "status -sb" -LogCommand $false

    if ($short.Success) {
        $shortLines = $short.StdOut -split "`r?`n"

        if ($shortLines.Count -gt 0) {
            $firstLine = $shortLines[0]

            if ($firstLine -match "\[(.+)\]") {
                $status.AheadBehind = $matches[1]
            }
        }
    }

    $status.HasConflicts = Test-MergeConflict -WorkingDirectory $Project.LocalPath

    if ($status.HasConflicts) {
        $status.ActionAllowed = "No - Conflicts"
    }
    elseif ($status.RemoteMatch -ne "Yes") {
        $status.ActionAllowed = "No - Remote Mismatch"
    }
    elseif ($status.CurrentBranch -eq "HEAD") {
        $status.ActionAllowed = "No - Detached HEAD"
    }
    elseif (Test-IsBlank -Value $status.CurrentBranch) {
        $status.ActionAllowed = "No - Unknown Branch"
    }
    elseif ($status.GitRepoStatus -ne "OK") {
        $status.ActionAllowed = "No - Not Git Repo"
    }
    else {
        $status.ActionAllowed = "Yes"
    }

    if (Test-IsBlank -Value $status.Message) {
        $status.Message = "OK"
    }

    return $status
}

function Refresh-List {
    $script:lvProjects.Items.Clear()
    $script:LastStatus = @()

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "No projects loaded." -Level "WARN"
        return
    }

    Write-GuiLog -Message "Checking project status..."

    foreach ($project in $script:Projects) {
        $status = Get-ProjectStatus -Project $project
        $script:LastStatus += $status

        $item = New-Object System.Windows.Forms.ListViewItem($status.Name)
        [void]$item.SubItems.Add($status.FolderStatus)
        [void]$item.SubItems.Add($status.GitRepoStatus)
        [void]$item.SubItems.Add($status.CurrentBranch)
        [void]$item.SubItems.Add($status.DefaultBranch)
        [void]$item.SubItems.Add($status.LocalStatus)
        [void]$item.SubItems.Add([string]$status.ChangeCount)
        [void]$item.SubItems.Add($status.AheadBehind)
        [void]$item.SubItems.Add($status.RemoteMatch)
        [void]$item.SubItems.Add($status.ActionAllowed)
        [void]$item.SubItems.Add($status.RemoteUrl)
        [void]$item.SubItems.Add($status.LocalPath)

        $item.Tag = $status

        if ($status.ActionAllowed -like "No*") {
            $item.BackColor = [System.Drawing.Color]::FromArgb(255, 225, 225)
        }
        elseif ($status.LocalStatus -eq "Modified") {
            $item.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 200)
        }
        elseif ($status.LocalStatus -eq "Clean") {
            $item.BackColor = [System.Drawing.Color]::FromArgb(220, 255, 220)
        }

        [void]$script:lvProjects.Items.Add($item)

        if ($status.Message -ne "OK") {
            Write-GuiLog -Message "$($status.Name): $($status.Message)" -Level "WARN"
        }
    }

    Write-GuiLog -Message "Status check completed."
}

function Get-SelectedStatus {
    if ($script:lvProjects.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Please select a project first.",
            "No project selected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        return $null
    }

    return $script:lvProjects.SelectedItems[0].Tag
}

function Test-SelectedProjectSafeForWrite {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,

        [string]$ActionName = "Git action"
    )

    if ($null -eq $Status) {
        return $false
    }

    if ($Status.FolderStatus -ne "OK") {
        Write-GuiLog -Message "$ActionName blocked. Folder status is not OK: $($Status.FolderStatus)" -Level "ERROR"
        return $false
    }

    if ($Status.GitRepoStatus -ne "OK") {
        Write-GuiLog -Message "$ActionName blocked. Not a valid Git repo." -Level "ERROR"
        return $false
    }

    if ($Status.RemoteMatch -ne "Yes") {
        Write-GuiLog -Message "$ActionName blocked. Configured repo URL does not match actual origin." -Level "ERROR"
        return $false
    }

    if ($Status.CurrentBranch -eq "HEAD") {
        Write-GuiLog -Message "$ActionName blocked. Detached HEAD detected." -Level "ERROR"
        return $false
    }

    if (Test-IsBlank -Value $Status.CurrentBranch) {
        Write-GuiLog -Message "$ActionName blocked. Current branch is blank or unknown." -Level "ERROR"
        return $false
    }

    if (Test-MergeConflict -WorkingDirectory $Status.LocalPath) {
        Write-GuiLog -Message "$ActionName blocked. Merge conflicts detected. Resolve manually first." -Level "ERROR"
        return $false
    }

    return $true
}

function Open-SelectedFolder {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    if (-not (Test-Path -LiteralPath $status.LocalPath)) {
        Write-GuiLog -Message "Folder does not exist: $($status.LocalPath)" -Level "ERROR"
        return
    }

    Write-GuiLog -Message "Opening folder: $($status.LocalPath)"

    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($status.LocalPath)`""
}

function Open-SelectedRepo {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    $repo = $status.ConfigRepoUrl

    if (Test-IsBlank -Value $repo) {
        $repo = $status.RemoteUrl
    }

    if (Test-IsBlank -Value $repo) {
        Write-GuiLog -Message "No repo URL found for selected project." -Level "WARN"
        return
    }

    $webUrl = ConvertTo-WebRepoUrl -RepoUrl $repo

    Write-GuiLog -Message "Opening repo: $webUrl"

    Start-Process -FilePath $webUrl
}

function Show-Details {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    $details = @()
    $details += "Name: $($status.Name)"
    $details += "Local Path: $($status.LocalPath)"
    $details += "Configured Repo URL: $($status.ConfigRepoUrl)"
    $details += "Actual Origin URL: $($status.RemoteUrl)"
    $details += "Default Branch: $($status.DefaultBranch)"
    $details += "Current Branch: $($status.CurrentBranch)"
    $details += "Folder Status: $($status.FolderStatus)"
    $details += "Git Repo Status: $($status.GitRepoStatus)"
    $details += "Local Status: $($status.LocalStatus)"
    $details += "Change Count: $($status.ChangeCount)"
    $details += "Ahead/Behind: $($status.AheadBehind)"
    $details += "Remote Match: $($status.RemoteMatch)"
    $details += "Has Conflicts: $($status.HasConflicts)"
    $details += "Action Allowed: $($status.ActionAllowed)"
    $details += "Message: $($status.Message)"

    [void][System.Windows.Forms.MessageBox]::Show(
        ($details -join "`r`n"),
        "Project Details",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Pull-SelectedProject {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    Write-GuiLog -Message "Pull Selected clicked for project: $($status.Name)"

    if (-not (Test-SelectedProjectSafeForWrite -Status $status -ActionName "Pull")) {
        return
    }

    if ($script:chkBlockPullWithChanges.Checked -and $status.ChangeCount -gt 0) {
        Write-GuiLog -Message "Pull blocked. Local changes exist and 'Block pull if local changes exist' is enabled." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Pull blocked because local changes exist.`r`n`r`nCommit or discard changes manually before pulling.",
            "Pull blocked",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $branchName = $status.CurrentBranch
    $result = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "pull --ff-only origin $branchName" -LogCommand $true

    if ($result.Success) {
        Write-GuiLog -Message "Pull completed successfully for $($status.Name)."
    }
    else {
        Write-GuiLog -Message "Pull failed for $($status.Name)." -Level "ERROR"
    }

    Refresh-List
}

function Commit-SelectedProject {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    Write-GuiLog -Message "Commit Selected clicked for project: $($status.Name)"

    if (-not (Test-SelectedProjectSafeForWrite -Status $status -ActionName "Commit")) {
        return
    }

    $message = $script:txtCommitMessage.Text

    if (Test-IsBlank -Value $message) {
        Write-GuiLog -Message "Commit blocked. Commit message is blank." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Please enter a commit message before committing.",
            "Commit message required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $porcelain = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "status --porcelain" -LogCommand $true

    if (-not $porcelain.Success) {
        Write-GuiLog -Message "Commit blocked. Failed to check local status." -Level "ERROR"
        return
    }

    if (Test-IsBlank -Value $porcelain.StdOut) {
        Write-GuiLog -Message "Commit skipped. No local changes detected."
        return
    }

    $addResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "add ." -LogCommand $true

    if (-not $addResult.Success) {
        Write-GuiLog -Message "Commit failed. git add failed." -Level "ERROR"
        Refresh-List
        return
    }

    $escapedMessage = Escape-GitMessage -Message $message
    $commitResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "commit -m `"$escapedMessage`"" -LogCommand $true

    if ($commitResult.Success) {
        Write-GuiLog -Message "Commit completed successfully for $($status.Name)."
    }
    else {
        Write-GuiLog -Message "Commit failed for $($status.Name)." -Level "ERROR"
    }

    Refresh-List
}

function Push-SelectedProject {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    Write-GuiLog -Message "Push Selected clicked for project: $($status.Name)"

    if (-not (Test-SelectedProjectSafeForWrite -Status $status -ActionName "Push")) {
        return
    }

    if ($script:chkConfirmPush.Checked) {
        $message = @()
        $message += "Push selected project?"
        $message += ""
        $message += "Project: $($status.Name)"
        $message += "Branch: $($status.CurrentBranch)"
        $message += "Remote: $($status.RemoteUrl)"
        $message += ""
        $message += "This will run:"
        $message += "git push origin $($status.CurrentBranch)"
        $message += ""
        $message += "Continue?"

        $answer = [System.Windows.Forms.MessageBox]::Show(
            ($message -join "`r`n"),
            "Confirm Push",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-GuiLog -Message "Push cancelled by user."
            return
        }
    }

    $branchName = $status.CurrentBranch
    $pushResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "push origin $branchName" -LogCommand $true

    if ($pushResult.Success) {
        Write-GuiLog -Message "Push completed successfully for $($status.Name)."
    }
    else {
        Write-GuiLog -Message "Push failed for $($status.Name)." -Level "ERROR"
    }

    Refresh-List
}

# ------------------------------------------------------------
# GUI creation
# ------------------------------------------------------------

Initialize-Log

$form = New-Object System.Windows.Forms.Form
$form.Text = "GitHub Project Sync Manager - Phase 2 Safe Manual Actions"
$form.Size = New-Object System.Drawing.Size(1480, 880)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1250, 760)

$fontDefault = New-Object System.Drawing.Font -ArgumentList "Segoe UI", ([single]9)
$fontBold = New-Object System.Drawing.Font -ArgumentList "Segoe UI", ([single]9), ([System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font -ArgumentList "Consolas", ([single]9)

$form.Font = $fontDefault
$script:form = $form

$lblConfig = New-Object System.Windows.Forms.Label
$lblConfig.Location = New-Object System.Drawing.Point(12, 12)
$lblConfig.Size = New-Object System.Drawing.Size(120, 22)
$lblConfig.Text = "Config file:"
$lblConfig.Font = $fontBold
$form.Controls.Add($lblConfig)

$txtConfigPath = New-Object System.Windows.Forms.TextBox
$txtConfigPath.Location = New-Object System.Drawing.Point(135, 10)
$txtConfigPath.Size = New-Object System.Drawing.Size(1000, 24)
$txtConfigPath.Text = $script:ConfigPath
$txtConfigPath.ReadOnly = $true
$form.Controls.Add($txtConfigPath)

$btnCreateSample = New-Object System.Windows.Forms.Button
$btnCreateSample.Location = New-Object System.Drawing.Point(1145, 8)
$btnCreateSample.Size = New-Object System.Drawing.Size(120, 28)
$btnCreateSample.Text = "Create Sample"
$form.Controls.Add($btnCreateSample)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Location = New-Object System.Drawing.Point(1275, 8)
$btnExit.Size = New-Object System.Drawing.Size(100, 28)
$btnExit.Text = "Exit"
$form.Controls.Add($btnExit)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Location = New-Object System.Drawing.Point(12, 45)
$btnLoad.Size = New-Object System.Drawing.Size(120, 32)
$btnLoad.Text = "Load Projects"
$form.Controls.Add($btnLoad)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Location = New-Object System.Drawing.Point(142, 45)
$btnCheck.Size = New-Object System.Drawing.Size(120, 32)
$btnCheck.Text = "Check Status"
$form.Controls.Add($btnCheck)

$btnPull = New-Object System.Windows.Forms.Button
$btnPull.Location = New-Object System.Drawing.Point(272, 45)
$btnPull.Size = New-Object System.Drawing.Size(120, 32)
$btnPull.Text = "Pull Selected"
$form.Controls.Add($btnPull)

$btnCommit = New-Object System.Windows.Forms.Button
$btnCommit.Location = New-Object System.Drawing.Point(402, 45)
$btnCommit.Size = New-Object System.Drawing.Size(120, 32)
$btnCommit.Text = "Commit Selected"
$form.Controls.Add($btnCommit)

$btnPush = New-Object System.Windows.Forms.Button
$btnPush.Location = New-Object System.Drawing.Point(532, 45)
$btnPush.Size = New-Object System.Drawing.Size(120, 32)
$btnPush.Text = "Push Selected"
$form.Controls.Add($btnPush)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Location = New-Object System.Drawing.Point(662, 45)
$btnOpenFolder.Size = New-Object System.Drawing.Size(120, 32)
$btnOpenFolder.Text = "Open Folder"
$form.Controls.Add($btnOpenFolder)

$btnOpenRepo = New-Object System.Windows.Forms.Button
$btnOpenRepo.Location = New-Object System.Drawing.Point(792, 45)
$btnOpenRepo.Size = New-Object System.Drawing.Size(140, 32)
$btnOpenRepo.Text = "Open GitHub Repo"
$form.Controls.Add($btnOpenRepo)

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Location = New-Object System.Drawing.Point(942, 45)
$btnDetails.Size = New-Object System.Drawing.Size(100, 32)
$btnDetails.Text = "Details"
$form.Controls.Add($btnDetails)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Location = New-Object System.Drawing.Point(1052, 45)
$btnClearLog.Size = New-Object System.Drawing.Size(100, 32)
$btnClearLog.Text = "Clear Log"
$form.Controls.Add($btnClearLog)

$lblCommit = New-Object System.Windows.Forms.Label
$lblCommit.Location = New-Object System.Drawing.Point(12, 88)
$lblCommit.Size = New-Object System.Drawing.Size(120, 22)
$lblCommit.Text = "Commit message:"
$lblCommit.Font = $fontBold
$form.Controls.Add($lblCommit)

$txtCommitMessage = New-Object System.Windows.Forms.TextBox
$txtCommitMessage.Location = New-Object System.Drawing.Point(135, 86)
$txtCommitMessage.Size = New-Object System.Drawing.Size(760, 24)
$txtCommitMessage.Text = ""
$form.Controls.Add($txtCommitMessage)
$script:txtCommitMessage = $txtCommitMessage

$chkConfirmPush = New-Object System.Windows.Forms.CheckBox
$chkConfirmPush.Location = New-Object System.Drawing.Point(915, 88)
$chkConfirmPush.Size = New-Object System.Drawing.Size(160, 22)
$chkConfirmPush.Text = "Confirm before push"
$chkConfirmPush.Checked = $true
$form.Controls.Add($chkConfirmPush)
$script:chkConfirmPush = $chkConfirmPush

$chkBlockPullWithChanges = New-Object System.Windows.Forms.CheckBox
$chkBlockPullWithChanges.Location = New-Object System.Drawing.Point(1085, 88)
$chkBlockPullWithChanges.Size = New-Object System.Drawing.Size(230, 22)
$chkBlockPullWithChanges.Text = "Block pull if local changes exist"
$chkBlockPullWithChanges.Checked = $true
$form.Controls.Add($chkBlockPullWithChanges)
$script:chkBlockPullWithChanges = $chkBlockPullWithChanges

$lblSafety = New-Object System.Windows.Forms.Label
$lblSafety.Location = New-Object System.Drawing.Point(12, 118)
$lblSafety.Size = New-Object System.Drawing.Size(1380, 22)
$lblSafety.Text = "Phase 2 safety: selected-project only. No force push, reset hard, clean, branch switching, or automatic conflict resolution."
$lblSafety.ForeColor = [System.Drawing.Color]::DarkGreen
$lblSafety.Font = $fontBold
$form.Controls.Add($lblSafety)

$lvProjects = New-Object System.Windows.Forms.ListView
$lvProjects.Location = New-Object System.Drawing.Point(12, 150)
$lvProjects.Size = New-Object System.Drawing.Size(1435, 420)
$lvProjects.View = "Details"
$lvProjects.FullRowSelect = $true
$lvProjects.GridLines = $true
$lvProjects.MultiSelect = $false
$lvProjects.HideSelection = $false

[void]$lvProjects.Columns.Add("Project Name", 240)
[void]$lvProjects.Columns.Add("Folder", 80)
[void]$lvProjects.Columns.Add("Git Repo", 95)
[void]$lvProjects.Columns.Add("Current Branch", 120)
[void]$lvProjects.Columns.Add("Default Branch", 120)
[void]$lvProjects.Columns.Add("Local Status", 100)
[void]$lvProjects.Columns.Add("Changes", 70)
[void]$lvProjects.Columns.Add("Ahead/Behind", 120)
[void]$lvProjects.Columns.Add("Remote Match", 110)
[void]$lvProjects.Columns.Add("Action Allowed", 170)
[void]$lvProjects.Columns.Add("Origin Remote URL", 280)
[void]$lvProjects.Columns.Add("Local Path", 450)

$form.Controls.Add($lvProjects)
$script:lvProjects = $lvProjects

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(12, 580)
$lblLog.Size = New-Object System.Drawing.Size(120, 22)
$lblLog.Text = "Log:"
$lblLog.Font = $fontBold
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 605)
$txtLog.Size = New-Object System.Drawing.Size(1435, 220)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = $fontMono
$form.Controls.Add($txtLog)
$script:txtLog = $txtLog

# ------------------------------------------------------------
# Event handlers
# ------------------------------------------------------------

$btnCreateSample.Add_Click({
    Create-SampleConfig
})

$btnLoad.Add_Click({
    Load-Projects
    Refresh-List
})

$btnCheck.Add_Click({
    if ($script:Projects.Count -eq 0) {
        Load-Projects
    }

    Refresh-List
})

$btnPull.Add_Click({
    Pull-SelectedProject
})

$btnCommit.Add_Click({
    Commit-SelectedProject
})

$btnPush.Add_Click({
    Push-SelectedProject
})

$btnOpenFolder.Add_Click({
    Open-SelectedFolder
})

$btnOpenRepo.Add_Click({
    Open-SelectedRepo
})

$btnDetails.Add_Click({
    Show-Details
})

$btnClearLog.Add_Click({
    $script:txtLog.Clear()
    Write-GuiLog -Message "Log cleared."
})

$btnExit.Add_Click({
    $form.Close()
})

$lvProjects.Add_DoubleClick({
    Show-Details
})

$form.Add_Shown({
    Write-GuiLog -Message "GitHub Project Sync Manager started."
    Write-GuiLog -Message "Phase: 2 - Safe Manual Actions"
    Write-GuiLog -Message "Config path: $script:ConfigPath"
    Write-GuiLog -Message "Log file: $script:LogFile"

    $script:GitAvailable = Test-GitInstalled

    if ($script:GitAvailable) {
        Write-GuiLog -Message "Git detected successfully."
    }
    else {
        Write-GuiLog -Message "Git was not found in PATH." -Level "ERROR"
    }

    Load-Projects

    if ($script:Projects.Count -gt 0) {
        Refresh-List
    }
})

# ------------------------------------------------------------
# Start GUI
# ------------------------------------------------------------

[void]$form.ShowDialog()



