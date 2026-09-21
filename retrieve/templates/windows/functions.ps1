$InformationPreference = "continue"
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues = @{ '*:Encoding' = 'utf8' }
trap
{
    "
#
# -------------!!   ERROR  !!-------------
#
# Installation or update of proxiport finished with errors.
#

Error in line $( $_.InvocationInfo.ScriptLineNumber )
    $_

Try the following to investigate:
1) sc query proxiport

2) open C:\Program Files\proxiport\proxiport.log

3) READ THE DOCS on https://docs.proxiport.net

4) Request support on https://github.com/proximile/proxiport/issues
"
    Set-Location $myLocation
    exit 1
}

$InstallerLogFile = $false
if (-not(Get-Command Write-Information -erroraction silentlycontinue))
{
    $InstallerLogFile = (Get-Location).path + "\proxiport-installer.log"
    if (Test-Path $InstallerLogFile)
    {
        Remove-Item $InstallerLogFile
    }
    Write-Output "# Compatibility mode for PowerShell $( $PSVersionTable.PSVersion ) activated"
    Write-Output "# All information stream messages are redirected to $( $InstallerLogFile )"
    function Write-Information
    {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Applies only to old PS Versions')]
        Param(
            [parameter(Mandatory = $false)]
            [String] $MessageData = ""
        )
        Add-Content -Path $InstallerLogFile -Value $MessageData
    }
}

function Get-Log
{
    if (Test-Path $InstallerLogFile)
    {
        Write-Output ""
        Write-Output "= The following information has been logged:"
        Get-Content $InstallerLogFile
        Remove-Item $InstallerLogFile -Force
    }
}

# Extract a ZIP file
function Get-StagingDir
{
    <#
    .SYNOPSIS
        Return an empty directory that only SYSTEM and Administrators can write to.
    .DESCRIPTION
        C:\Windows\Temp must never be used to stage anything a privileged
        process later reads, executes or copies into place. Its default DACL
        grants BUILTIN\Users:(CI)(S,WD,AD,X) -- create files and create
        subdirectories -- and the (CI) flag inherits into every subdirectory at
        every depth, including one SYSTEM created. So any unprivileged local
        user can fill an empty slot there and have it picked up. %ProgramFiles%
        grants BUILTIN\Users read and execute only, which is what makes it a
        safe staging root.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [String] $Path
    )
    if (Test-Path $Path)
    {
        Remove-Item $Path -Recurse -Force
    }
    # Deliberately no -Force on the create: an unprivileged user cannot create
    # this path, so if something is still there after the Remove-Item, stop
    # rather than reuse it.
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    return $Path
}

function Expand-Zip
{
    Param(
        [parameter(Mandatory = $true)]
        [String] $Path,
        [parameter(Mandatory = $true)]
        [String] $DestinationPath
    )
    # The PowerShell < 5 fallback below empties the destination before
    # extracting, so a ZIP staged inside the directory it extracts to is deleted
    # before it can be read. Refuse rather than fail obscurely on exactly the
    # old PowerShell versions the fallback exists for.
    #
    # Compare whole path components, not raw string prefixes. A bare
    # StartsWith also fires on a SIBLING whose name merely begins with the
    # destination's -- and that is exactly how install.ps1 stages, in
    # "%ProgramFiles%\proxiport-install-tmp" next to "%ProgramFiles%\proxiport".
    # A raw prefix test made every fresh ZIP install throw here, after mkdir
    # had already created the install directory, so the retry then refused
    # with "ProxiPort is already installed".
    $archivePath = $Path -replace '/', '\'
    $destinationPrefix = ($DestinationPath -replace '/', '\').TrimEnd('\') + '\'
    if ($archivePath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Refusing to extract $( $Path ) into $( $DestinationPath ): the archive is inside its own destination."
    }
    if (Get-Command Expand-Archive -errorAction SilentlyContinue)
    {
        Expand-Archive -Path $Path -DestinationPath $DestinationPath -force
    }
    else
    {
        # Use a fallback for old powershells < 5
        Remove-Item (-join ($DestinationPath, "\*")) -force -Recurse
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $DestinationPath)
    }
}

function Add-ToConfig
{
    [OutputType([String[]])]
    Param(
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent,
        [parameter(Mandatory = $true)]
        [String] $Block,
        [parameter(Mandatory = $true)]
        [String] $Line
    )
    <#
    .SYNOPSIS
        Add a line to a block of a the proxiport toml configuration.
    #>
    # Join before testing, exactly as Set-TomlVar does. `-notmatch` with an
    # ARRAY on its left is a filter, not a boolean: it returns every element
    # that does not match, which for any real config is a non-empty array and
    # therefore always truthy. The "append the missing block" branch ran every
    # single time, and "$configContent" then flattened the whole file into one
    # space-separated line. Because a proxiport.conf opens with a #==== banner,
    # that commented out the agent's entire configuration -- server URL, auth
    # credential and fingerprint included -- and update.ps1 wrote it straight
    # back before restarting the service, so the host never reconnected and
    # could only be fixed with physical or RDP access.
    $lines = @($ConfigContent)
    $blockPattern = "^\s*\[" + [Regex]::Escape($Block) + "\]"
    if (($lines -join "`n") -notmatch "(?m)$blockPattern")
    {
        $lines += ''
        $lines += "[$Block]"
    }

    Write-Information "* Adding `"$Line`" to [$Block]"

    # Rebuilt line by line rather than -replace over joined text, so the array
    # shape that update.ps1 hands to WriteAllLines survives the call.
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $lines)
    {
        $text = [string]$entry
        $out.Add($text)
        if ($text -match $blockPattern)
        {
            $out.Add("  $Line")
        }
    }
    , $out.ToArray()
}

function Find-Interpreter
{
    <#
    .SYNOPSIS
        Find common script interpreters installed on the system
    #>
    $interpreters = @{
    }
    if (Test-Path -Path 'C:\Program Files\PowerShell\7\pwsh.exe')
    {
        $interpreters.add('powershell7', 'C:\Program Files\PowerShell\7\pwsh.exe')
    }
    if (Test-Path -Path 'C:\Program Files\Git\bin\bash.exe')
    {
        $interpreters.add('bash', 'C:\Program Files\Git\bin\bash.exe')
    }
    $interpreters
}

function Enable-FileReception
{
    [OutputType([String])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent,
        [Parameter(Mandatory)]
        [Boolean]$Switch
    )

    if ($Switch)
    {
        try
        {
            $ConfigContent = Set-TomlVar -ConfigContent $ConfigContent "file-reception" -Key "enabled" -value "true"
            Write-Information "* File reception has been enabled."
        }
        catch
        {
            Write-Information ": Enabling file-reception failed."
            Write-Information ": Check the settings of [file-reception] manually and change to your needs."
        }

    }
    else
    {
        try
        {
            $ConfigContent = Set-TomlVar -ConfigContent $ConfigContent "file-reception" -Key "enabled" -value "false"
            Write-Information "* File reception has been disabled."
        }
        catch
        {
            Write-Information ": Disabling file-reception failed."
            Write-Information ": Check the settings of [file-reception] manually and change to your needs."
        }

    }


    $ConfigContent
    return
}

function Enable-InterpreterAlias
{
    <#
    .SYNOPSIS
        Push interpreters to the proxiport.conf
    #>
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent
    )

    Write-Information "* Looking for script interpreters."
    $interpreters = Find-Interpreter
    Write-Information "* $( $interpreters.count ) script interpreters found."
    if ($interpreters.count -eq 0)
    {
        $ConfigContent
        return
    }
    $interpreters.keys|ForEach-Object {
        $key = $_
        $value = $interpreters[$_]
        if (Test-TomlKeyExist -ConfigContent $ConfigContent -Block "interpreter-aliases" -Key $key)
        {
            Write-Information ": $key already present in configuration."
        }
        else
        {
            $ConfigContent = Add-ToConfig -ConfigContent $configContent -Block "interpreter-aliases" -Line "$( $key ) = '$( $value )'"
        }
    }
    $configContent
}

function Test-TomlKeyExist
{
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent,
        [Parameter(Mandatory)]
        [String]$Block,
        [Parameter(Mandatory)]
        [String]$Key
    )
    if (($ConfigContent -join "`n") -notmatch ("(?m)^\[" + [Regex]::Escape($Block) + "\]"))
    {
        $ConfigContent
        Write-Error "Block [$( $Block )] not found in config content"
        $false
        return
    }
    $inBlock = $false
    foreach ($Line in $ConfigContent -split "`n")
    {
        if ($Line -match "^\[$( $Block )\]")
        {
            $inBlock = $true
        }
        elseif ($Line -match "^\[.*\]")
        {
            $inBlock = $false
        }
        if ($inBlock -and ($line -match "$key = ") -and ($line -notmatch "#.*$key ="))
        {
            $true
            return
        }
    }
    $false
    return
}

function Set-TomlVar
{
    [OutputType([String])]
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent,
        [Parameter(Mandatory)]
        [String]$Block,
        [Parameter(Mandatory)]
        [String]$Key,
        [Parameter(Mandatory)]
        [String]$Value
    )
    if (($ConfigContent -join "`n") -notmatch ("(?m)^\[" + [Regex]::Escape($Block) + "\]"))
    {
        Write-Error "Block [$( $Block )] not found in config content"
        $configContent
        return
    }
    $inBlock = $false
    $new = ""
    $ok = $false
    foreach ($Line in $configContent -split "`n")
    {
        if ($Line -match "^\[$( $Block )\]")
        {
            $inBlock = $true
        }
        elseif ($Line -match "^\[.*\]")
        {
            $inBlock = $false
        }
        if ($inBlock -and ($line -match "^([#, ])*$key = "))
        {
            $new = $new + "  $key = $value`n"
            $ok = $true
            $inBlock = $false
        }
        else
        {
            $new = $new + $line + "`n"
        }
    }
    if (-not$ok)
    {
        $e = @()
        $e += ": Key '$( $Key )' not found in config section [$( $Block )]."
        $e += ": Please add manually '$( $Key ) = `"$( $Value )`"'"
        Write-Error ($e -join "`n")
        return
    }
    if ( $PSCmdlet.ShouldProcess($ConfigContent))
    {
        Write-Debug $new
    }
    $new
    return
}

function Add-Netcard
{
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent,
        [Parameter(Mandatory)]
        [CimInstance[]]$Interface,
        [Parameter(Mandatory)]
        [ValidateSet('net_lan', 'net_wan')]
        [String]$InterfaceType
    )
    if ($Interface.Length -gt 1)
    {
        Write-Information ""
        Write-Information "-----------------------::CAUTION::-----------------------"
        Write-Information ": You have more than one connected $( $InterfaceType ) card."
        Write-Information ": Just the first one will be activated for the monitoring."
        Write-Information ": Review the configuration file and adjust to your needs manually once the installation has finished."
        Write-Information ""
    }
    $InterfaceAlias = $Interface[0].InterfaceAlias
    $linkSpeed = ((Get-Netadapter|Where-Object Name -eq $InterfaceAlias)[0].LinkSpeed) -replace " Gbps", "000" -replace " Mbps", ""
    $linkSpeed = [math]::floor($linkSpeed);
    if (Test-TomlKeyExist -ConfigContent $ConfigContent -Block "monitoring" -Key $InterfaceType)
    {
        Write-Information "* Monitoring for $InterfaceType '$InterfaceAlias' already activated. Skipping."
        $ConfigContent
        return
    }
    try
    {
        $ConfigContent = Set-TomlVar -ConfigContent $ConfigContent -Block "monitoring" -Key $InterfaceType -Value "['$InterfaceAlias', '$linkSpeed']"
        Write-Information "* Monitoring for $InterfaceType '$InterfaceAlias' activated."
    }
    catch
    {
        Write-Information ": Monitoring for $InterfaceType '$InterfaceAlias' NOT activated."
        Write-Information $_
    }
    $ConfigContent
}

function Select-EnabledNetCard
{
    [OutputType([Object[]])]
    param (
        [Parameter(Position = 1, ValueFromPipeline = $true)]
        [object[]]$NetAdapters
    )
    process
    {
        $filtered = @()
        foreach ($NetAdapter in $NetAdapters)
        {
            try
            {
                if ("Up" -eq (Get-NetAdapter -Name $NetAdapter.InterfaceAlias).Status)
                {
                    $filtered += $NetAdapter
                }
            }
            catch
            {
                Write-Information ": Failed to get status of $( $NetAdapter.InterfaceAlias ). Net Adapter ignored."
            }

        }
        $filtered
        return
    }
}

function Enable-Network-Monitoring
{
    [OutputType([Object[]])]
    param (
        [Parameter(Mandatory)]
        [Object[]]$ConfigContent
    )
    if ($ConfigContent -match "^\s*net_[lw]an")
    {
        Write-Information "* Network Monitoring already enabled."
        $ConfigContent
        return
    }
    try
    {
        $netLan = (Get-NetIPAddress|Where-Object IPAddress -Match "^(10|192.168|172.16)"|Select-EnabledNetCard)
        $netWan = (Get-NetIPAddress|Where-Object AddressFamily -eq "IPv4"|Where-Object IPAddress -NotMatch "^(10|192.168|172.16|127.|169.254.)"|Select-EnabledNetCard)
    }
    catch
    {
        Write-Information ": Getting list of Network adapters with 'Get-NetIPAddress' failed. Notwork monitoring not activated."
        $ConfigContent
        return
    }

    if (-Not$netLan -and -Not$netWan)
    {
        Write-Information "* No Lan cards detected. Check manually with 'Get-NetAdapter'"
        $ConfigContent
        return
    }
    if ($netLan)
    {
        $ConfigContent = Add-Netcard -ConfigContent $ConfigContent -Interface $netLan -InterfaceType 'net_lan'
    }
    if ($netWan)
    {
        $ConfigContent = Add-Netcard -ConfigContent $ConfigContent -Interface $netWan -InterfaceType 'net_wan'
    }
    $ConfigContent
}

function Get-HostUUID
{
    try
    {
        (Get-CimInstance -Class Win32_ComputerSystemProduct).UUID
        return
    }
    catch
    {
        Write-Information ": Reading system UUID with 'Get-CimInstance -Class Win32_ComputerSystemProduct' failed."
        Write-Information ": Falling back to a md5 hash of the computer name."
        $hash = [System.Security.Cryptography.HashAlgorithm]::Create("md5").ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($( $env:computername )))
        [System.BitConverter]::ToString($hash).Replace("-", "")
        return
    }
}

# Set the start type of the service
function Optimize-ServiceStartup
{
    param()
    #@formatter:off
    & sc.exe config proxiport start= delayed-auto
    & sc.exe failure proxiport reset= 0 actions= restart/5000
    #@formatter:on
}

# Resolve the latest release tag (e.g. "v0.1.4") of proximile/proxiport
# via the GitHub API, falling back to the /releases/latest redirect.
function Get-LatestReleaseTag
{
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try
    {
        $resp = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/proximile/proxiport/releases/latest"
        if ($resp.tag_name)
        {
            return $resp.tag_name
        }
    }
    catch
    {
        Write-Information "* GitHub API lookup failed, following the releases/latest redirect instead."
    }
    $request = [System.Net.WebRequest]::Create("https://github.com/proximile/proxiport/releases/latest")
    $request.AllowAutoRedirect = $true
    $response = $request.GetResponse()
    $tag = ($response.ResponseUri.AbsolutePath -split '/')[-1]
    $response.Close()
    if (-not $tag)
    {
        Write-Error "Could not determine the latest proximile/proxiport release tag."
    }
    return $tag
}

# Verify the SHA-256 of a downloaded release asset against the release's
# published checksums.txt, aborting on mismatch. Mirrors the Linux installer's
# verify_checksum. checksums.txt is produced by the release pipeline
# (goreleaser) for every release.
# Best-effort Sigstore verification of checksums.txt. When cosign is present it
# verifies the release's keyless signature over checksums.txt against the pinned
# signing identity, throwing on failure -- this is what defends against a
# same-channel attacker who can rewrite both the artifact and checksums.txt. When
# cosign is absent it warns and returns, leaving only the SHA-256 check.
function Confirm-ReleaseSignature
{
    Param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$ChecksumsFile
    )
    if (-not (Get-Command cosign -ErrorAction SilentlyContinue))
    {
        Write-Warning "cosign not found -- the release signature over checksums.txt is not being verified. Install cosign for full supply-chain verification."
        return
    }
    Write-Information "* Verifying release signature with cosign"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $base = "https://github.com/proximile/proxiport/releases/download/$( $Tag )"
    $sigFile = "$( $ChecksumsFile ).sig"
    $pemFile = "$( $ChecksumsFile ).pem"
    try
    {
        Invoke-WebRequest -UseBasicParsing -Uri "$( $base )/checksums.txt.sig" -OutFile $sigFile
        Invoke-WebRequest -UseBasicParsing -Uri "$( $base )/checksums.txt.pem" -OutFile $pemFile
    }
    catch
    {
        throw "cosign is installed but the release signature/certificate could not be downloaded -- refusing to install."
    }
    & cosign verify-blob `
        --certificate $pemFile `
        --signature $sigFile `
        --certificate-identity-regexp 'https://github.com/proximile/proxiport' `
        --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' `
        $ChecksumsFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0)
    {
        throw "cosign signature verification failed for checksums.txt -- refusing to install a possibly-tampered release."
    }
    Write-Information "* Signature OK (cosign)"
}

function Confirm-ReleaseChecksum
{
    Param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$StagingDir
    )
    $sumsUrl = "https://github.com/proximile/proxiport/releases/download/$( $Tag )/checksums.txt"
    Write-Information "* Verifying checksum against $( $sumsUrl )"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Download to a file (rather than into memory) so cosign can verify the exact
    # signed bytes.
    # Not $Env:TEMP: as SYSTEM that is C:\Windows\Temp, where any local user
    # can pre-create this file and keep ownership of it (Invoke-WebRequest
    # -OutFile truncates rather than recreates, so the attacker's DACL
    # survives). This file is the integrity input the checksum is read from, so
    # it has to be somewhere only SYSTEM and Administrators can write.
    $sumsFile = Join-Path $StagingDir "proxiport-checksums.txt"
    foreach ($stale in @($sumsFile, "$( $sumsFile ).sig", "$( $sumsFile ).pem"))
    {
        if (Test-Path $stale)
        {
            Remove-Item $stale -Force -Recurse
        }
    }
    try
    {
        Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -OutFile $sumsFile
    }
    catch
    {
        throw "Could not download checksums.txt -- refusing to install an unverified binary."
    }

    Confirm-ReleaseSignature -Tag $Tag -ChecksumsFile $sumsFile

    $expected = $null
    foreach ($line in (Get-Content $sumsFile))
    {
        # checksums.txt lines are "<sha256>  <filename>"
        $parts = ($line.Trim() -split '\s+', 2)
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $AssetName)
        {
            $expected = $parts[0].Trim().ToLower()
            break
        }
    }
    if (-not $expected)
    {
        throw "No checksum listed for $( $AssetName ) -- refusing to install an unverified binary."
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $FilePath).Hash.ToLower()
    if ($expected -ne $actual)
    {
        throw "Checksum mismatch for $( $AssetName ): expected $expected, got $actual. The download may have been tampered with; not installing."
    }
    Write-Information "* Checksum OK ($actual)"
}

function Invoke-Download
{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$StagingDir,
        [Parameter()]
        [string]$gt = "0",
        [string]$pkgUrl,
        # An explicit release to fetch, from the updater's -v switch. Empty
        # means "whatever GitHub calls latest". Without this the switch was
        # accepted, advertised in -h, and then ignored: an operator pinning a
        # fleet back to the last good build got the release they were rolling
        # back from, with no warning and a "finished" message.
        [string]$Version
    )
    $Headers = @{ }
    # Set for the GitHub-release download path so the download can be checksum-
    # verified below. Left empty for a custom $pkgUrl (no published checksums),
    # matching the Linux installer, which also only verifies release downloads.
    $assetName = $null
    $releaseTag = $null
    if ($pkgUrl)
    {
        # Download from a custom URL given by global switch
        # https only. A custom package URL is not checksum-verified (there are
        # no published checksums for it), so the transport is the only thing
        # standing between this and running an attacker's binary as the service
        # account.
        if ($pkgUrl -match ("^https://.*windows_x86_64\.zip$"))
        {
            $downloadFile = Join-Path $StagingDir 'proxiport_windows_x86_64.zip'
        }
        else
        {
            throw "PkgUrl $( $pkgUrl ) is not a valid proxiport download url: it must be an https:// URL ending in windows_x86_64.zip."
        }
        $url = $pkgUrl
        if ($env:PROXIPORT_INSTALLER_DL_USERNAME -and $env:PROXIPORT_INSTALLER_DL_PASSWORD)
        {
            $pair = "$( $env:PROXIPORT_INSTALLER_DL_USERNAME ):$( $env:PROXIPORT_INSTALLER_DL_PASSWORD )"
            $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
            $basicAuthValue = "Basic $encodedCreds"
            $Headers = @{
                Authorization = $basicAuthValue
            }
            Write-Information "* Downloading using HTTP basic auth"
        }
    }
    else
    {
        # Download the zip of the latest GitHub release. ProxiPort
        # publishes no MSI packages.
        if ($Version)
        {
            $tag = If ($Version -match '^v')
            {
                $Version
            }
            Else
            {
                "v$( $Version )"
            }
        }
        else
        {
            $tag = Get-LatestReleaseTag
        }
        $version = $tag -replace '^v', ''
        if ($gt -ne "0" -and $version -eq $gt)
        {
            # Already on the latest version: hand back an empty file,
            # which callers treat as "no update needed".
            $downloadFile = Join-Path $StagingDir 'proxiport-up-to-date.zip'
            New-Item -ItemType File -Force -Path $downloadFile | Out-Null
            return $downloadFile
        }
        $assetName = "proxiport_$( $version )_windows_x86_64.zip"
        $downloadFile = Join-Path $StagingDir $assetName
        $url = "https://github.com/proximile/proxiport/releases/download/$( $tag )/$( $assetName )"
        $releaseTag = $tag
    }

    # -PathType leaf missed a plant that is a directory, which then made
    # Invoke-WebRequest fail and aborted the whole install.
    if (Test-Path $downloadFile)
    {
        Remove-Item $downloadFile -Force -Recurse
    }
    Write-Information "* Downloading  $( $url )."
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $downloadFile -Headers $Headers
    if ($releaseTag -and $assetName)
    {
        # Verify the release download before any caller extracts/runs it.
        Confirm-ReleaseChecksum -FilePath $downloadFile -AssetName $assetName -Tag $releaseTag -StagingDir $StagingDir
    }
    return $downloadFile
}

# Create an uninstaller script for proxiport
function New-Uninstaller
{
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Set-Content -Path "$( $installDir )\uninstall.bat" -Value '
ECHO off
net session > NUL
IF %ERRORLEVEL% EQU 0 (
    ECHO You are Administrator. Fine ...
) ELSE (
    ECHO You are NOT Administrator. Exiting...
    PING -n 5 127.0.0.1 > NUL 2>&1
    EXIT /B 1
)
echo Removing proxiport now
ping -n 5 127.0.0.1 > null
sc stop proxiport
"%PROGRAMFILES%"\proxiport\proxiport.exe --service uninstall -c "%PROGRAMFILES%"\proxiport\proxiport.conf
cd C:\
rmdir /S /Q "%PROGRAMFILES%"\proxiport\
echo ProxiPort removed
ping -n 2 127.0.0.1 > null
'
    Write-Output "* Uninstaller created in $( $installDir )\uninstall.bat."
}

function New-PSScriptFile
{
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $ScriptBlock
    )
    # Out-File -Append into a path that already exists would add to whatever is
    # there rather than replace it, so a pre-created file becomes a prefix of
    # the script that runs.
    if (Test-Path $Path)
    {
        throw "Refusing to write $( $Path ): it already exists."
    }
    New-Item -ItemType File -Path $Path -ErrorAction Stop | Out-Null
    $ScriptBlock.Split("`n") | ForEach-Object {
        if ($_)
        {
            $_.Trim() | Out-File -FilePath $Path -Append
        }
    }
    $null = $Path
}

function Get-MSIVersionInfo
{
    param (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.IO.FileInfo] $path
    )
    if (!(Test-Path $path.FullName))
    {
        throw "File '{0}' does not exist" -f $path.FullName
    }
    try
    {
        $WindowsInstaller = New-Object -com WindowsInstaller.Installer
        $Database = $WindowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $Null, $WindowsInstaller, @($path.FullName, 0))
        $Query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
        $View = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $Null, $Database, ($Query))
        $View.GetType().InvokeMember("Execute", "InvokeMethod", $Null, $View, $Null) | Out-Null
        $Record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $Null, $View, $Null)
        $Version = $Record.GetType().InvokeMember("StringData", "GetProperty", $Null, $Record, 1)
        return $Version
    }
    catch
    {
        throw "Failed to get MSI file version: {0}." -f $_
    }
}