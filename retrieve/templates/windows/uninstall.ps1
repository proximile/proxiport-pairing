#Requires -RunAsAdministrator
# Remove the ProxiPort client from this Windows host. Assembled by the pairing
# service's /uninstall route (header.txt + this file) and served as a download;
# run it from an elevated PowerShell. Mirrors the paths install.ps1 sets up.

$ErrorActionPreference = "Stop"
$installDir = "$( $Env:Programfiles )\proxiport"
$exe = "$( $installDir )\proxiport.exe"

Write-Output " Uninstall the ProxiPort client"

# Refuse if a proxiportd server is running here -- the client and server share
# the install directory, and removing it would take the server down too.
if (Get-Process -Name proxiportd -ErrorAction SilentlyContinue) {
    Write-Warning "You are running the proxiportd server on this machine. Uninstall the client manually."
    exit 0
}

# Stop and remove the service via the client's own service manager, then fall
# back to Stop-Service in case the process is still up.
if (Get-Service -Name proxiport -ErrorAction SilentlyContinue) {
    if (Test-Path $exe) {
        & $exe --service stop 2>$null
        & $exe --service uninstall 2>$null
    }
    Stop-Service -Name proxiport -ErrorAction SilentlyContinue
}

# Remove the install directory (binary, config, data, logs, attributes file all
# live under it).
if (Test-Path $installDir) {
    Remove-Item -Recurse -Force $installDir
    Write-Output " [ DELETED ] $( $installDir )"
}

Write-Output " [ FINISH  ] ProxiPort client removed."
Write-Output ""
Write-Output "# Feedback and bug reports: https://github.com/proximile/proxiport/issues"
