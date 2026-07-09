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
$script:ProjectRunState = @{}
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

        $lastChecked = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $runState = Get-ProjectRunState -ProjectName $status.Name

        [void]$item.SubItems.Add($lastChecked)
        [void]$item.SubItems.Add($runState.LastAction)
        [void]$item.SubItems.Add($runState.LastResult)
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

    $runState = Get-ProjectRunState -ProjectName $status.Name
    $details += "Last Action: $($runState.LastAction)"
    $details += "Last Result: $($runState.LastResult)"
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
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Pull Selected" -LastResult "Success"
    }
    else {
        Write-GuiLog -Message "Pull failed for $($status.Name)." -Level "ERROR"
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Pull Selected" -LastResult "Failed"
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
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Commit Selected" -LastResult "Skipped - No Changes"
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
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Commit Selected" -LastResult "Success"
    }
    else {
        Write-GuiLog -Message "Commit failed for $($status.Name)." -Level "ERROR"
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Commit Selected" -LastResult "Failed"
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
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Push Selected" -LastResult "Success"
    }
    else {
        Write-GuiLog -Message "Push failed for $($status.Name)." -Level "ERROR"
        Set-ProjectRunState -ProjectName $status.Name -LastAction "Push Selected" -LastResult "Failed"
    }

    Refresh-List
}

# ------------------------------------------------------------
# GUI creation
# ------------------------------------------------------------

Initialize-Log

$form = New-Object System.Windows.Forms.Form
$form.Text = "GitHub Project Sync Manager - Phase 5.2 Last Action Tracking"
$form.Size = New-Object System.Drawing.Size(1680, 880)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1450, 760)

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
$txtConfigPath.Size = New-Object System.Drawing.Size(1180, 24)
$txtConfigPath.Text = $script:ConfigPath
$txtConfigPath.ReadOnly = $true
$form.Controls.Add($txtConfigPath)

$btnCreateSample = New-Object System.Windows.Forms.Button
$btnCreateSample.Location = New-Object System.Drawing.Point(1330, 8)
$btnCreateSample.Size = New-Object System.Drawing.Size(120, 28)
$btnCreateSample.Text = "Create Sample"
$form.Controls.Add($btnCreateSample)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Location = New-Object System.Drawing.Point(1460, 8)
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
$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Location = New-Object System.Drawing.Point(662, 45)
$btnSync.Size = New-Object System.Drawing.Size(120, 32)
$btnSync.Text = "Sync Selected"
$form.Controls.Add($btnSync)
$btnPreviewSyncAll = New-Object System.Windows.Forms.Button
$btnPreviewSyncAll.Location = New-Object System.Drawing.Point(792, 45)
$btnPreviewSyncAll.Size = New-Object System.Drawing.Size(140, 32)
$btnPreviewSyncAll.Text = "Preview Sync All"
$form.Controls.Add($btnPreviewSyncAll)
$btnSyncAll = New-Object System.Windows.Forms.Button
$btnSyncAll.Location = New-Object System.Drawing.Point(942, 45)
$btnSyncAll.Size = New-Object System.Drawing.Size(120, 32)
$btnSyncAll.Text = "Sync All"
$form.Controls.Add($btnSyncAll)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Location = New-Object System.Drawing.Point(1072, 45)
$btnOpenFolder.Size = New-Object System.Drawing.Size(120, 32)
$btnOpenFolder.Text = "Open Folder"
$form.Controls.Add($btnOpenFolder)

$btnOpenRepo = New-Object System.Windows.Forms.Button
$btnOpenRepo.Location = New-Object System.Drawing.Point(1202, 45)
$btnOpenRepo.Size = New-Object System.Drawing.Size(140, 32)
$btnOpenRepo.Text = "Open GitHub Repo"
$form.Controls.Add($btnOpenRepo)

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Location = New-Object System.Drawing.Point(1352, 45)
$btnDetails.Size = New-Object System.Drawing.Size(100, 32)
$btnDetails.Text = "Details"
$form.Controls.Add($btnDetails)


$btnExportReport = New-Object System.Windows.Forms.Button
$btnExportReport.Location = New-Object System.Drawing.Point(1462, 45)
$btnExportReport.Size = New-Object System.Drawing.Size(100, 32)
$btnExportReport.Text = "Export Report"
$form.Controls.Add($btnExportReport)
$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Location = New-Object System.Drawing.Point(1572, 45)
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
$lblSafety.Text = "Phase 5.2 safety: Last action tracking is UI/reporting only. Git safety rules remain unchanged."
$lblSafety.ForeColor = [System.Drawing.Color]::DarkGreen
$lblSafety.Font = $fontBold
$form.Controls.Add($lblSafety)

$lvProjects = New-Object System.Windows.Forms.ListView
$lvProjects.Location = New-Object System.Drawing.Point(12, 150)
$lvProjects.Size = New-Object System.Drawing.Size(1635, 420)
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
[void]$lvProjects.Columns.Add("Last Checked", 150)
[void]$lvProjects.Columns.Add("Last Action", 160)
[void]$lvProjects.Columns.Add("Last Result", 150)
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
$txtLog.Size = New-Object System.Drawing.Size(1635, 220)
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
$btnSync.Add_Click({
    Sync-SelectedProject
})
$btnPreviewSyncAll.Add_Click({
    Preview-SyncAllProjects
})
$btnSyncAll.Add_Click({
    Sync-AllProjects
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


$btnExportReport.Add_Click({
    Export-SyncReport
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
    Write-GuiLog -Message "Phase: 5.2 - Last Action Tracking"
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


function Sync-SelectedProject {
    $status = Get-SelectedStatus

    if ($null -eq $status) {
        return
    }

    Write-GuiLog -Message "Sync Selected clicked for project: $($status.Name)"

    if (-not (Test-SelectedProjectSafeForWrite -Status $status -ActionName "Sync")) {
        return
    }

    $commitMessage = $script:txtCommitMessage.Text
    $hasLocalChanges = $false

    if ($status.ChangeCount -gt 0) {
        $hasLocalChanges = $true
    }

    if ($hasLocalChanges -and (Test-IsBlank -Value $commitMessage)) {
        Write-GuiLog -Message "Sync blocked. Local changes exist but commit message is blank." -Level "WARN"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Local changes exist for the selected project.`r`n`r`nPlease enter a commit message before using Sync Selected.",
            "Commit message required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        return
    }

    $plannedActions = @()

    if ($hasLocalChanges) {
        $plannedActions += "Commit local changes"
    }
    else {
        $plannedActions += "Skip commit because no local changes were detected"
    }

    $plannedActions += "Pull latest changes using git pull --ff-only"
    $plannedActions += "Push current branch to origin"

    $summary = @()
    $summary += "Sync selected project?"
    $summary += ""
    $summary += "Project: $($status.Name)"
    $summary += "Path: $($status.LocalPath)"
    $summary += "Branch: $($status.CurrentBranch)"
    $summary += "Remote match: $($status.RemoteMatch)"
    $summary += "Local status: $($status.LocalStatus)"
    $summary += "Local changes: $($status.ChangeCount)"
    $summary += "Action allowed: $($status.ActionAllowed)"
    $summary += ""
    $summary += "Planned actions:"

    foreach ($plannedAction in $plannedActions) {
        $summary += "- $plannedAction"
    }

    $summary += ""
    $summary += "Safety rules:"
    $summary += "- No force push"
    $summary += "- No reset hard"
    $summary += "- No git clean"
    $summary += "- No branch switching"
    $summary += "- No automatic conflict resolution"
    $summary += "- Stop on first failure"
    $summary += ""
    $summary += "Continue?"

    $answer = [System.Windows.Forms.MessageBox]::Show(
        ($summary -join "`r`n"),
        "Confirm Sync Selected",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-GuiLog -Message "Sync cancelled by user."
        return
    }

    $branchName = $status.CurrentBranch

    if ($hasLocalChanges) {
        Write-GuiLog -Message "Sync step 1: checking local changes."

        $statusResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "status --porcelain" -LogCommand $true

        if (-not $statusResult.Success) {
            Write-GuiLog -Message "Sync failed. Could not check local status." -Level "ERROR"
            Refresh-List
            return
        }

        if (-not (Test-IsBlank -Value $statusResult.StdOut)) {
            Write-GuiLog -Message "Sync step 2: staging local changes."

            $addResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "add ." -LogCommand $true

            if (-not $addResult.Success) {
                Write-GuiLog -Message "Sync failed. git add failed. Stopping before commit, pull, or push." -Level "ERROR"
                Refresh-List
                return
            }

            Write-GuiLog -Message "Sync step 3: committing local changes."

            $safeMessage = Escape-GitMessage -Message $commitMessage
            $commitResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "commit -m `"$safeMessage`"" -LogCommand $true

            if (-not $commitResult.Success) {
                Write-GuiLog -Message "Sync failed. git commit failed. Stopping before pull or push." -Level "ERROR"
                Refresh-List
                return
            }

            Write-GuiLog -Message "Sync commit step completed successfully."
        }
        else {
            Write-GuiLog -Message "No local changes detected at runtime. Commit step skipped."
        }
    }
    else {
        Write-GuiLog -Message "Sync commit step skipped. No local changes were detected."
    }

    Write-GuiLog -Message "Sync step 4: pulling latest changes with fast-forward only."

    $pullResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "pull --ff-only origin $branchName" -LogCommand $true

    if (-not $pullResult.Success) {
        Write-GuiLog -Message "Sync failed. Pull failed. Push was not attempted." -Level "ERROR"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Sync failed during pull.`r`n`r`nPush was not attempted.`r`n`r`nCheck the GUI log for details.",
            "Sync failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )

        Refresh-List
        return
    }

    Write-GuiLog -Message "Sync pull step completed successfully."

    Write-GuiLog -Message "Sync step 5: pushing current branch to origin."

    $pushResult = Invoke-GitCommand -WorkingDirectory $status.LocalPath -Arguments "push origin $branchName" -LogCommand $true

    if (-not $pushResult.Success) {
        Write-GuiLog -Message "Sync failed. Push failed." -Level "ERROR"

        [void][System.Windows.Forms.MessageBox]::Show(
            "Sync failed during push.`r`n`r`nCheck the GUI log for details.",
            "Sync failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )

        Refresh-List
        return
    }

    Write-GuiLog -Message "Sync push step completed successfully."
    Write-GuiLog -Message "Sync completed successfully for $($status.Name)."
    Set-ProjectRunState -ProjectName $status.Name -LastAction "Sync Selected" -LastResult "Success"

    Refresh-List

    [void][System.Windows.Forms.MessageBox]::Show(
        "Sync completed successfully.`r`n`r`nProject: $($status.Name)`r`nBranch: $branchName",
        "Sync complete",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}


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
    foreach ($status in $script:LastStatus) { Set-ProjectRunState -ProjectName $status.Name -LastAction "Preview Sync All" -LastResult "Previewed" }
    Refresh-List

    [void][System.Windows.Forms.MessageBox]::Show(
        $summaryText,
        "Preview Sync All",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}


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
            Set-ProjectRunState -ProjectName $status.Name -LastAction "Sync All" -LastResult "Success"
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


function Export-SyncReport {
    Write-GuiLog -Message "Export Report clicked."

    if ($script:Projects.Count -eq 0) {
        Write-GuiLog -Message "No projects loaded. Loading projects before export."
        Load-Projects
    }

    if ($script:Projects.Count -gt 0) {
        Write-GuiLog -Message "Refreshing project status before export."
        Refresh-List
    }

    $reportsFolder = Join-Path -Path $script:ScriptRoot -ChildPath "reports"

    if (-not (Test-Path -LiteralPath $reportsFolder)) {
        New-Item -Path $reportsFolder -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportPath = Join-Path -Path $reportsFolder -ChildPath "GitHubProjectSync_Report_$timestamp.txt"

    $report = @()
    $report += "GitHub Project Sync Manager Report"
    $report += "Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")"
    $report += "Phase: 5.1 - Export Sync Report"
    $report += "Config path: $script:ConfigPath"
    $report += "Log file: $script:LogFile"
    $report += ""

    if ($script:LastStatus.Count -eq 0) {
        $report += "No project status results were available."
        $report += "Use Check Status, Preview Sync All, Sync Selected, or Sync All before exporting for a fuller report."
        $report += ""
    }
    else {
        $report += "Project Summary"
        $report += "---------------"
        $report += "Projects found: $($script:LastStatus.Count)"
        $report += ""

        $projectNumber = 1
        $cleanCount = 0
        $modifiedCount = 0
        $blockedCount = 0
        $safeCount = 0

        foreach ($status in $script:LastStatus) {
            if ($status.LocalStatus -eq "Clean") {
                $cleanCount++
            }

            if ($status.LocalStatus -eq "Modified") {
                $modifiedCount++
            }

            if ($status.ActionAllowed -eq "Yes") {
                $safeCount++
            }
            else {
                $blockedCount++
            }

            $report += "$projectNumber. $($status.Name)"
            $report += "   Local path: $($status.LocalPath)"
            $report += "   Current branch: $($status.CurrentBranch)"
            $report += "   Default branch: $($status.DefaultBranch)"
            $report += "   Folder status: $($status.FolderStatus)"
            $report += "   Git repo status: $($status.GitRepoStatus)"
            $report += "   Local status: $($status.LocalStatus)"
            $report += "   Changes: $($status.ChangeCount)"
            $report += "   Ahead/Behind: $($status.AheadBehind)"
            $report += "   Remote match: $($status.RemoteMatch)"
            $report += "   Action allowed: $($status.ActionAllowed)"
            $report += "   Origin remote URL: $($status.RemoteUrl)"
            $report += ""

            $projectNumber++
        }

        $report += "Totals"
        $report += "------"
        $report += "Safe projects: $safeCount"
        $report += "Blocked projects: $blockedCount"
        $report += "Clean projects: $cleanCount"
        $report += "Modified projects: $modifiedCount"
        $report += ""
    }

    $report += "Visible GUI Log"
    $report += "---------------"

    if ($null -ne $script:txtLog) {
        if ($script:txtLog.Text.Trim().Length -gt 0) {
            $report += $script:txtLog.Text
        }
        else {
            $report += "The visible GUI log was empty at export time."
        }
    }
    else {
        $report += "The GUI log control was not available."
    }

    Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8

    Write-GuiLog -Message "Report exported to: $reportPath"
    foreach ($status in $script:LastStatus) { Set-ProjectRunState -ProjectName $status.Name -LastAction "Export Report" -LastResult "Report Exported" }
    Refresh-List

    [void][System.Windows.Forms.MessageBox]::Show(
        "Report exported successfully.`r`n`r`n$reportPath",
        "Export Report",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}


function Get-ProjectRunState {
    param(
        [string]$ProjectName
    )

    if ($null -eq $script:ProjectRunState) {
        $script:ProjectRunState = @{}
    }

    if ($null -eq $ProjectName -or $ProjectName.Trim().Length -eq 0) {
        return [PSCustomObject]@{
            LastAction = ""
            LastResult = ""
        }
    }

    if ($script:ProjectRunState.ContainsKey($ProjectName)) {
        return $script:ProjectRunState[$ProjectName]
    }

    return [PSCustomObject]@{
        LastAction = ""
        LastResult = ""
    }
}

function Set-ProjectRunState {
    param(
        [string]$ProjectName,
        [string]$LastAction,
        [string]$LastResult
    )

    if ($null -eq $script:ProjectRunState) {
        $script:ProjectRunState = @{}
    }

    if ($null -eq $ProjectName -or $ProjectName.Trim().Length -eq 0) {
        return
    }

    $state = [PSCustomObject]@{
        LastAction = $LastAction
        LastResult = $LastResult
    }

    $script:ProjectRunState[$ProjectName] = $state
}

[void]$form.ShowDialog()










