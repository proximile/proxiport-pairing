#Requires -RunAsAdministrator
# Definition of command line parameters
Param(
# Use unstable version yes/no
    [Switch]$t,
# Enable scripts
    [Switch]$x,
# Disable scripts
    [Switch]$d,
# Show a help message
    [Switch]$h,
# Force update
    [Switch]$f,
# Install a specific version
    [String]$v,
# Enable file reception
    [Switch]$r,
# Use a specific version from any URL
    [string]$pkgUrl,
# Without cosign, and when the pinned cosign can't be downloaded, accept the SHA-256 check alone
    [switch]$k
)
$AllowNoCosign = [bool]$k