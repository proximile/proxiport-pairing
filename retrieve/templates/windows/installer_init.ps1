<#
        .SYNOPSIS
        Installs the proxiport clients and connects it to the server

        .DESCRIPTION
        This script will download the latest version of the proxiport client,
        create the configuration and connect to the server.
        You can change the configuration by editing C:\Program Files\proxiport\proxiport.conf
        ProxiPort runs as a service with a local system account.

        .PARAMETER x
        Enable the execution of scripts via proxiport.

        .PARAMETER t
        Use the latest unstable development release. Dangerous!

        .PARAMETER i
        Install Tascoscript along with the ProxiPort Client

        .PARAMETER r
        Enable file recption

        .PARAMETER g
        Add a custom tag

        .PARAMETER d
        Write the config and exit. Service will not be installed. Mainly for testing.

        .INPUTS
        None. You cannot pipe objects.

        .OUTPUTS
        System.String. Add-Extension returns success banner or a failure message.

        .EXAMPLE
        PS> powershell -ExecutionPolicy Bypass -File .\proxiport-installer.ps1 -x
        Install and connext with script execution enabled.

        .EXAMPLE
        PS> powershell -ExecutionPolicy Bypass -File .\proxiport-installer.ps1
        Install and connect with script execution disabled.

        .LINK
        Online help: https://docs.proxiport.net/connecting-clients#advanced-pairing-options
#>
#Requires -RunAsAdministrator
# Definition of command line parameters
Param(
    [Alias("EnableCommands")][switch]$x, # Enable remote commands yes/no
    [switch]$t, # Use unstable version yes/no
    [switch]$i, # Install tacoscript
    [switch]$r, # Enable file reception
    [string]$g, # Add a tag
    [switch]$d, # Exit after writing the config
    [string]$pkgUrl
)
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64")
{
    Write-Output "Only 64bit Windows on x86_64 supported. Sorry."
    Exit 1
}