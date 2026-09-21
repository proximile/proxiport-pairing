if ($h)
{
    Write-Output "Update the proxiport client.
Invoking without parameters updates to the latest stable version.

Parameters:
-t  Use the latest unstable version.
-x  Enable command and script execution without asking for confirmation.
-d  Disable command and script execution.
-v [version] Upgrade to the specified version.
-f  force update without comparing versions
-r  activate file reception
"
    exit
}
# -t asked for an unstable build. ProxiPort publishes no prereleases, and the
# value computed here was never read by anything -- so the switch installed
# stable while the operator believed otherwise. Say so instead of deciding it
# silently; the switch is still accepted, so nobody's existing command line
# starts erroring out.
if ($t)
{
    Write-Output "* -t was given, but ProxiPort publishes no unstable releases. Installing the stable release."
}
$enableScripts = $null
$enableScripts = If ($x)
{
    "true"
}
$enableScripts = If ($d)
{
    "false"
}

$myLocation = (Get-Location).path
$configFile = 'C:\Program Files\proxiport\proxiport.conf'
$installDir = "$( $Env:Programfiles )\proxiport"
if (-Not(Test-Path "$( $installDir )\proxiport.exe"))
{
    Write-Output "You don't have ProxiPort installed. Nothing to do."
    exit 0
}
Set-Location $installDir
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($f)
{
    # If current version is set to 0 an update will always be forced
    Write-Output "* Forcing an update or redownload"
    $currentVersion = '0'
}
else
{
    $versionString = (& 'C:\Program Files\proxiport\proxiport.exe' --version)
    $currentVersion = $( $versionString -split " " )[1]
}

# One-time cleanup. Earlier versions staged the new binary in
# C:\windows\temp\proxiport-update, a directory any local user can create
# files in. Remove whatever is there -- including anything planted -- rather
# than leave it for a privileged process to find.
if (Test-Path 'C:\windows\temp\proxiport-update')
{
    Remove-Item 'C:\windows\temp\proxiport-update' -Recurse -Force -ErrorAction SilentlyContinue
}

# Stage under the install directory, which grants BUILTIN\Users read and
# execute only. The download goes in the install directory itself rather than
# in the extraction directory, because Expand-Zip's PowerShell < 5 fallback
# empties its destination before extracting.
$stagingDir = Get-StagingDir -Path "$( $installDir )\update"

$downloadFile = Invoke-Download -gt $currentVersion -pkgUrl $pkgUrl -StagingDir $installDir -Version $v
If ((Get-Item $downloadFile).length -eq 0)
{
    Write-Output "* No ProxiPort update needed. You are on the latest $currentVersion version."
    Remove-Item $downloadFile
    Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Set-Location $myLocation
    exit 0
}
Write-Output "* Download finished and stored to $( $downloadFile ) ."

# ProxiPort publishes no MSI packages: Invoke-Download only ever returns a
# .zip, so the MSI and MSI-migration branches that used to be here could not
# run. They are gone, along with the two extra code paths they left in the
# scheduled task that runs as SYSTEM.
Write-Output "* Extracting ProxiPort.exe to $stagingDir"
Expand-Zip -Path $downloadFile -DestinationPath $stagingDir
Remove-Item $downloadFile
if (Test-Path (Join-Path $stagingDir 'proxiport.example.conf'))
{
    Remove-Item (Join-Path $stagingDir 'proxiport.example.conf') -Force
}
$targetVersion = (& (Join-Path $stagingDir 'proxiport.exe') --version) -replace "version ", ""
Write-Output "* New version will be $targetVersion."

# Hand exactly one file across to the scheduled task, at a path only SYSTEM and
# Administrators can write, and drop the staging directory now. proxiport is
# still running so its own exe cannot be replaced yet; Invoke-Later does the
# swap once the current connection has been closed.
Move-Item (Join-Path $stagingDir 'proxiport.exe') "$( $installDir )\proxiport.new.exe" -Force
Remove-Item $stagingDir -Recurse -Force



function ExtendConfig
{
    Add-Content -Path $configFile -Value "[remote-scripts]
  enabled = $( $enableScripts )"
}
function abortOnNoTerminal
{
    if ([System.Environment]::UserInteractive)
    {
        return
    }
    Remove-Item -Path $downloadFile -Force
    $host.ui.WriteErrorLine('This script cannot run without a terminal because questions are asked.')
    $host.ui.WriteErrorLine("Execute with '-x' to enable remote script execution or ")
    $host.ui.WriteErrorLine("execute with '-d' to disable remote script execution.")
    exit 1
}
function askForScriptEnabling
{
    abortOnNoTerminal
    do
    {
        $yesNo = Read-Host -prompt 'Do you want to enabale remote script execution? Y/N'
        if ( $yesNo.Tolower().StartsWith('y'))
        {
            $enableScripts = 'true'
            return $enableScripts
        }
        elseif ( $yesNo.ToLower().StartsWith('n'))
        {
            $enableScripts = 'false'
            return $enableScripts
        }
    } while ($true)
}
# Check if the config needs an update
if (Select-String -Path $configFile -Pattern "[remote-scripts]")
{
    Write-Output "* Scripts are already configured. Not changing."
}
else
{
    if ($null -eq $enableScripts)
    {
        askForScriptEnabling
    }
    ExtendConfig
}

# Add file reception to the config file
function Add-FileRecption
{
    if ((Get-Content $configFile) -match "^\[file-reception\]")
    {
        Write-Output "* Monitoring already enabled."
        return
    }
    Add-Content -Path $configFile -Value "
[file-reception]
  ## Receive files pushed by the server, enabled by default
  # enabled = true
  ## The proxiport client will reject writing files to any of the following folders and its subfolders.
  ## https://docs.proxiport.net/docs/no18-file-upload.html
  ## Wildcards (glob) are supported.
  ## Linux defaults
  # protected = ['/bin', '/sbin', '/boot', '/usr/bin', '/usr/sbin', '/dev', '/lib*', '/run']
  ## Windows defaults
  # protected = ['C:\Windows\', 'C:\ProgramData']
"
}

# Add Monitoring reception to the config file
function Add-Monitoring
{
    if ((Get-Content $configFile) -match "^\[monitoring\]")
    {
        Write-Output "* Monitoring section already present in configuration file."
        return
    }
    Add-Content -Path $configFile -Value "
[monitoring]
  ## The proxiport client can collect and report performance data of the operating system.
  ## https://docs.proxiport.net/docs/no17-monitoring.html
  ## Monitoring is enabled by default
  enabled = true
  ## How often (seconds) monitoring data should be collected.
  ## A value below 60 seconds will be overwritten by the hard-coded default of 60 seconds.
  # interval = 60
  ## ProxiPort monitors the fill level of almost all volumes or mount points.
  ## Change the below defaults to include or exclude volumes or mount points from the monitoring.
  #fs_type_include = ['ext3','ext4','xfs','jfs','ntfs','btrfs','hfs','apfs','exfat','smbfs','nfs']
  ## List of excluded mount points or device letters
  #fs_path_exclude = []
  ## Example:
  # fs_path_exclude = ['/mnt/*','h:']
  ## Having fs_path_exclude_recurse = false the specified path
  ## must match a mountpoint or it will be ignored
  ## Having fs_path_exclude_recurse = true the specified path
  ## can be any folder and all mountpoints underneath will be excluded
  #fs_path_exclude_recurse = false
  ## To avoid monitoring of so-called mount binds,
  ## mount points are identified by the path and device name.
  ## Mountpoints pointing to the same device are ignored.
  ## What appears first in /proc/self/mountinfo is considered as the original.
  ## Applies only to Linux
  #fs_identify_mountpoints_by_device = true
  ## ProxiPort monitors all running processes
  ## Process monitoring is enabled by default
  pm_enabled = true
  ## Monitor kernel tasks identified by process group 0
  #pm_enable_kerneltask_monitoring = true
  ## The process list is sorted by PID descending. Only the top N processes are monitored.
  #pm_max_number_monitored_processes = 500
  ## Monitor the bandwidth usage of the following maximum two network cards:
  ## 'net_lan' and 'net_wan'.
  ## You must specify the device name and the maximum speed in Megabits.
  ## On Windows use 'Get-Netadapter' to discover adapter names.
  ## Examples:
  ## net_lan = [ 'eth0' , '1000' ]
  ## net_wan = ['Ethernet0', '1000']
  #net_lan = ['', '1000']
  #net_wan = ['', '1000']"
}

function Add-WatchdogIntegration
{
    <#
    .SYNOPSIS
        Push watchdog integration to the proxiport.conf
    #>
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent
    )

    if ($ConfigContent -match "watchdog_integration")
    {
        Write-Information "* Watchdog Integration already present in configuration file."
        return $ConfigContent
    }

    if ([System.Version]$targetVersion -lt [System.Version]"0.8.8")
    {
        Write-Information "* Version $( $targetVersion ) does not support watchdog integration"
        return $ConfigContent
    }

    $watchdogSnippet = "
  ## Write a state file to {data_dir}/state.json that can be evaluated by external watchdog implementations.
  ## On Linux this also enables the systemd watchdog integration by using the systemd notify socket.
  ## Requires max_retry_count = -1 and keep_alive > 0
  ## Read more https://docs.proxiport.net/advanced/watchdog-integration/
  ## Disabled by default.
  #watchdog_integration = false
"
    $ConfigContent -replace "## Optionally set the 'Host' header", "$( $watchdogSnippet )`n`n  $&"
    Write-Information "* watchdog integration inserted"
}

function Invoke-Later
{
    Param
    (
        [Parameter(Mandatory = $true)]
        [string] $ScriptBlock,
        [Parameter(Mandatory = $false)]
        [int] $Delay = 10,
        [Parameter(Mandatory = $false)]
        [string] $Description = "Background Task"
    )
    $taskName = 'Invoke-Later-' + (Get-Random)
    # Not the machine TEMP directory: as SYSTEM that is C:\Windows\Temp, where
    # any local user can create files. This one is written by an elevated
    # process and then executed by SYSTEM, so it belongs where BUILTIN\Users
    # cannot create anything. It also must not go in the staging directory,
    # which every run of this script wipes -- a second run inside the delay
    # window would delete a pending task's script and leave the task orphaned.
    $taskFile = Join-Path $installDir "$( $taskName ).ps1"
    if (Test-Path $taskFile)
    {
        throw "Refusing to write $( $taskFile ): it already exists."
    }
    New-Item -ItemType File -Path $taskFile -ErrorAction Stop | Out-Null
    $ScriptBlock.Split("`n") | ForEach-Object {
        if ($_)
        {
            $_.Trim() | Out-File -FilePath $taskFile -Append
        }
    }
    "Unregister-ScheduledTask -Taskname $( $taskName ) -Confirm:`$false" | Out-File -FilePath $taskFile -Append
    "Remove-Item `"$( $taskFile )`" -Force" | Out-File -FilePath $taskFile -Append
    # The task-script path now contains a space, so -File must be quoted, and
    # the interpreter is named by full path rather than resolved through PATH.
    $action = New-ScheduledTaskAction `
        -Execute "$( $Env:SystemRoot )\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$( $taskFile )`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds($Delay)
    $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries
    $task = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Settings $settings
    Register-ScheduledTask $taskName -InputObject $task
    Write-Output "* Task `"$( $Description )`" [$( $taskFile )] scheduled."
    Write-Output "  It will be executed within $( $Delay ) seconds."
}

# Add new features
Add-Monitoring
Add-FileRecption
# Enable new features
$configContent = Get-Content $configFile -Encoding utf8
$configContent = Enable-InterpreterAlias -ConfigContent $configContent
$configContent = Enable-Network-Monitoring -ConfigContent $configContent
# Enable/Disable file reception
$configContent = Enable-FileReception -ConfigContent $configContent -Switch $r
# Insert watchdog integration
$configContent = Add-WatchdogIntegration -ConfigContent $configContent
# Finally, write the config to a file
$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
[IO.File]::WriteAllLines($configFile, $configContent, $Utf8NoBomEncoding)

# Set the service startup and recovery actions
Optimize-ServiceStartup

# Create a scheduled task to restart ProxiPort.
try
{
    # This block is stringified, so nothing in it interpolates: the paths must
    # be literals. It is also the only thing that runs as SYSTEM after the
    # script exits, so it does exactly one thing -- move a file that only
    # SYSTEM and Administrators could have written. Move-Item leaves the source
    # in place if it fails, so a failed swap leaves proxiport.new.exe for the
    # operator instead of silently reverting to the old binary with nothing to
    # retry from.
    Invoke-Later -Description "Restart ProxiPort" -Delay 10 -ScriptBlock {
        Stop-Service proxiport
        $newExe = 'C:\Program Files\proxiport\proxiport.new.exe'
        if (Test-Path $newExe)
        {
            Move-Item $newExe 'C:\Program Files\proxiport\proxiport.exe' -Force
        }
        Start-Service proxiport
    }
}
catch
{
    # proxiport.new.exe is already staged, so there is nothing to copy: the
    # instructions below act on it directly.
    Write-Output ": Scheduling the restart of proxiport failed"
    Write-Output ": Try the following on your PowerShell to activate the new version."
    Write-Output "PS >
    Stop-Service proxiport
    Move-Item 'C:\Program Files\proxiport\proxiport.new.exe'  'C:\Program Files\proxiport\proxiport.exe' -Force
    Start-Service proxiport

    "
    Write-Output ": CAUTION: **Don't do the above while connected over ProxiPort!**"
}
Set-Location $myLocation

Get-Log

Write-Output "
#  Update of proxiport finished.
#
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#  Give us a star on https://github.com/proximile/proxiport
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

Thanks for using
   ____                   _____  _____           _
  / __ \                 |  __ \|  __ \         | |
 | |  | |_ __   ___ _ __ | |__) | |__) |__  _ __| |_
 | |  | | '_ \ / _ \ '_ \|  _  /|  ___/ _ \| '__| __|
 | |__| | |_) |  __/ | | | | \ \| |  | (_) | |  | |_
  \____/| .__/ \___|_| |_|_|  \_\_|   \___/|_|   \__|
        | |
        |_|
"