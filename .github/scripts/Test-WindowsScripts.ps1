<#
.SYNOPSIS
    Exercise the rendered Windows client scripts on a real Windows host.

.DESCRIPTION
    The Windows installer and updater are a few hundred lines of PowerShell that
    run elevated on every Windows host, and nothing outside a real Windows
    machine can tell us whether they parse, what rights the directories they use
    actually grant, or what the update staging sequence leaves behind. This
    checks all three.

    Checks are of two kinds, and the distinction is deliberate:

      GATE        an invariant that must hold. A failure fails the run.
      MEASURED    something observed and recorded rather than asserted, either
                  because it is evidence for a decision (the directory rights)
                  or because it describes behaviour that is known to be wrong
                  and is not yet fixed. Never silently dropped: every measured
                  value is printed and written to the job summary.

    Nothing here needs the network, and nothing installs the client.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ScriptDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = @()
$script:Summary = New-Object System.Collections.Generic.List[string]

function Write-Section
{
    param([string] $Title)
    Write-Host ""
    Write-Host "=== $Title ==="
    $script:Summary.Add("")
    $script:Summary.Add("### $Title")
    $script:Summary.Add("")
}

function Assert-That
{
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][bool] $Condition,
        [string] $Detail = ''
    )
    if ($Condition)
    {
        Write-Host "  GATE  pass  $Name"
        $script:Summary.Add("- **GATE pass** -- $Name")
    }
    else
    {
        Write-Host "  GATE  FAIL  $Name"
        if ($Detail) { Write-Host "              $Detail" }
        $script:Failures += "$Name$( if ($Detail) { " -- $Detail" } )"
        $script:Summary.Add("- **GATE FAIL** -- $Name$( if ($Detail) { " ($Detail)" } )")
    }
}

function Write-Measured
{
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
    )
    Write-Host "  MEAS        $Name = $Value"
    $script:Summary.Add("- MEASURED -- ${Name}: ``$Value``")
}

function Invoke-Native
{
    <#
        Windows PowerShell turns a native command's stderr into an error record
        when it is merged into the success stream, which under an ErrorAction of
        Stop aborts the run on output that is merely informational. Native exit
        codes are what we actually judge these calls on.
    #>
    param([Parameter(Mandatory = $true)][scriptblock] $Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 } finally { $ErrorActionPreference = $previous }
}

# The renderer wraps each included template in BEGINNING/END marker comments.
# Slicing on those gives us exactly the bytes the service served for one
# template, which is what we want to drive directly.
function Get-RenderedSection
{
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $Content,
        [Parameter(Mandatory = $true)][string] $Section
    )
    $start = -1
    $end = -1
    for ($i = 0; $i -lt $Content.Count; $i++)
    {
        if ($start -lt 0 -and $Content[$i] -match "^#\s+BEGINNING of\s+$([regex]::Escape($Section))\s") { $start = $i + 1; continue }
        if ($start -ge 0 -and $Content[$i] -match "^#\s+END of\s+$([regex]::Escape($Section))\s") { $end = $i - 1; break }
    }
    if ($start -lt 0 -or $end -lt $start)
    {
        throw "could not find section '$Section' in the rendered script"
    }
    return ($Content[$start..$end] -join "`n")
}


# ---------------------------------------------------------------------------
Write-Section "PowerShell parses"
# A syntax error in a rendered script is a total outage for every Windows host
# that fetches it, and no Go test can see one.

$rendered = @{ }
foreach ($file in @('installer.ps1', 'update.ps1', 'uninstall.ps1'))
{
    $path = Join-Path $ScriptDir $file
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $rendered[$file] = Get-Content -Path $path

    Assert-That -Name "$file parses with no syntax errors" -Condition ($errors.Count -eq 0) `
        -Detail (($errors | ForEach-Object { "line $( $_.Extent.StartLineNumber ): $( $_.Message )" }) -join '; ')
}


# ---------------------------------------------------------------------------
Write-Section "PSScriptAnalyzer"
# Gated on Error severity only. Warnings are reported, not gated: the scripts
# carry pre-existing style warnings and turning them all into gates in one go
# would mean either a red default branch or a suppression list nobody reads.

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer))
{
    Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck | Out-Null
}
Import-Module PSScriptAnalyzer

foreach ($file in $rendered.Keys | Sort-Object)
{
    $results = Invoke-ScriptAnalyzer -Path (Join-Path $ScriptDir $file) -Severity Error, Warning
    $errorsFound = @($results | Where-Object { $_.Severity -eq 'Error' })
    $warnings = @($results | Where-Object { $_.Severity -eq 'Warning' })

    Assert-That -Name "$file has no PSScriptAnalyzer errors" -Condition ($errorsFound.Count -eq 0) `
        -Detail (($errorsFound | ForEach-Object { "line $( $_.Line ): $( $_.RuleName )" }) -join '; ')
    Write-Measured -Name "$file PSScriptAnalyzer warnings" -Value $warnings.Count

    foreach ($w in ($warnings | Group-Object RuleName | Sort-Object Count -Descending))
    {
        Write-Host "                $( $w.Name ) x$( $w.Count )"
    }
}


# ---------------------------------------------------------------------------
Write-Section "Directory rights the update path depends on"
# The updater stages the new binary in one directory and installs it from
# another. Whether that is safe depends on who can write to each, which is a
# property of the running system, not of our code -- so measure it here rather
# than reasoning about it from documentation.
#
# A hosted runner is not a stock install, and its rights can be more permissive
# than a customer machine's: this one carries an explicit BUILTIN\Users:(F) on
# the temp directory where a default install grants only (CI)(S,WD,AD,X). The
# full access control list is printed for exactly that reason. The gates below
# assert only the direction that matters and that holds either way -- writable
# staging directory, non-writable install directory -- rather than an exact set
# of rights that would be reading a census off one machine.

function Format-Right
{
    <#
        FileSystemRights is a flags enum whose combined values mostly do not map
        back to a single name, so it prints as a bare signed integer. Several
        bits also carry two names depending on whether the object is a file or a
        directory; both are shown because these paths are directories that the
        update path writes files into.
    #>
    param([System.Security.AccessControl.FileSystemRights] $Rights)
    $bits = [ordered]@{
        'ListDirectory/ReadData'        = 0x1
        'CreateFiles/WriteData'         = 0x2
        'CreateDirectories/AppendData'  = 0x4
        'ReadExtendedAttributes'        = 0x8
        'WriteExtendedAttributes'       = 0x10
        'ExecuteFile/Traverse'          = 0x20
        'DeleteSubdirectoriesAndFiles'  = 0x40
        'ReadAttributes'                = 0x80
        'WriteAttributes'               = 0x100
        'Delete'                        = 0x10000
        'ReadPermissions'               = 0x20000
        'ChangePermissions'             = 0x40000
        'TakeOwnership'                 = 0x80000
    }
    $present = @()
    foreach ($name in $bits.Keys)
    {
        if (([int] $Rights -band $bits[$name]) -eq $bits[$name]) { $present += $name }
    }
    if (-not $present) { return '(none)' }
    return ($present -join ', ')
}

function Get-AllowedRights
{
    param([string] $Path, [string] $Identity)
    $acl = Get-Acl -Path $Path
    $rules = @($acl.Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq $Identity
    })
    $rights = [System.Security.AccessControl.FileSystemRights] 0
    foreach ($rule in $rules) { $rights = $rights -bor $rule.FileSystemRights }
    return [pscustomobject]@{
        Rights          = $rights
        InheritanceFlags = ($rules | ForEach-Object { $_.InheritanceFlags }) -join ','
        RuleCount       = $rules.Count
    }
}

$windowsTemp = Join-Path $Env:SystemRoot 'Temp'
$programFiles = $Env:ProgramFiles

foreach ($pair in @(@{ Path = $windowsTemp; Label = 'Windows\Temp' }, @{ Path = $programFiles; Label = 'Program Files' }))
{
    Write-Host "  icacls $( $pair.Path ):"
    Invoke-Native { & icacls $pair.Path } | ForEach-Object { Write-Host "    $_" }
    $u = Get-AllowedRights -Path $pair.Path -Identity 'BUILTIN\Users'
    Write-Measured -Name "$( $pair.Label ) BUILTIN\Users rights" -Value (Format-Right -Rights $u.Rights)
    Write-Measured -Name "$( $pair.Label ) BUILTIN\Users inheritance" -Value $u.InheritanceFlags
}

$tempUsers = Get-AllowedRights -Path $windowsTemp -Identity 'BUILTIN\Users'
$pfUsers = Get-AllowedRights -Path $programFiles -Identity 'BUILTIN\Users'
$createFiles = [System.Security.AccessControl.FileSystemRights]::CreateFiles

# The contrast is the whole point: an unprivileged account can drop a file into
# the staging directory but not into the install directory. Both halves are
# Windows defaults, so both are safe to gate on.
Assert-That -Name "unprivileged users can create files in $windowsTemp" `
    -Condition (($tempUsers.Rights -band $createFiles) -eq $createFiles)
Assert-That -Name "unprivileged users cannot create files in $programFiles" `
    -Condition (($pfUsers.Rights -band $createFiles) -ne $createFiles)


# ---------------------------------------------------------------------------
Write-Section "Update staging leaves a binary for the restart task to install"
# Drives the updater's own extract-and-stage sequence, taken out of the rendered
# script through its syntax tree rather than restated here, so this cannot drift
# from what ships.
#
# The sequence is the run of statements from the Expand-Zip call to the end of
# the block containing it, stopping at the first function definition. That
# identifies it whether the staging code sits inside a branch or at the top
# level, so the check survives the surrounding script being reorganised.

$updateBody = Get-RenderedSection -Content $rendered['update.ps1'] -Section 'templates/windows/update.ps1'
$functionsBody = Get-RenderedSection -Content $rendered['update.ps1'] -Section 'templates/windows/functions.ps1'

$errors = $null
$updateAst = [System.Management.Automation.Language.Parser]::ParseInput($updateBody, [ref]$null, [ref]$errors)

$expandCall = $updateAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Expand-Zip'
}, $true) | Select-Object -First 1

if (-not $expandCall)
{
    throw "could not find the Expand-Zip call in the rendered update script"
}

# Walk out to the statement the call belongs to, then to the block holding it.
$stagingStatement = $expandCall
while ($stagingStatement.Parent -and -not ($stagingStatement.Parent -is [System.Management.Automation.Language.StatementBlockAst] -or
                                            $stagingStatement.Parent -is [System.Management.Automation.Language.NamedBlockAst]))
{
    $stagingStatement = $stagingStatement.Parent
}
$stagingBlockAst = $stagingStatement.Parent
$statements = @($stagingBlockAst.Statements)
$firstIndex = [Array]::IndexOf($statements, $stagingStatement)

$stagingStatements = @()
for ($i = $firstIndex; $i -lt $statements.Count; $i++)
{
    if ($statements[$i] -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
    $stagingStatements += $statements[$i]
}
$stagingBlock = ($stagingStatements | ForEach-Object { $_.Extent.Text }) -join "`n"
Write-Host "  extracted $( $stagingStatements.Count ) statement(s) beginning at line $( $stagingStatements[0].Extent.StartLineNumber ) of the update script"

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("staging-" + [System.Guid]::NewGuid().ToString('N'))
$installDir = Join-Path $sandbox 'proxiport'
$staging = Join-Path $installDir 'update'
$payload = Join-Path $sandbox 'payload'
New-Item -ItemType Directory -Force -Path $payload | Out-Null
New-Item -ItemType Directory -Force -Path $staging | Out-Null

# A real console executable, so the version probe behaves as it does against a
# real release archive.
Add-Type -TypeDefinition 'public static class Stub { public static void Main() { System.Console.WriteLine("version 9.9.9"); } }' `
    -OutputAssembly (Join-Path $payload 'proxiport.exe') -OutputType ConsoleApplication
'# placeholder' | Set-Content -Path (Join-Path $payload 'proxiport.example.conf')

$archive = Join-Path $installDir 'proxiport_9.9.9_Windows_x86_64.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $archive

# The fixture the archive was built from has to go before anything counts
# survivors, or it would itself satisfy the check and the gate would pass
# whatever staging did.
Remove-Item -LiteralPath $payload -Recurse -Force

$funcFile = Join-Path $sandbox 'functions.ps1'
Set-Content -Path $funcFile -Value $functionsBody -Encoding UTF8

# Both the staging directory and the download path are established above the
# extracted sequence, so supply them under names either version may use.
$driver = Join-Path $sandbox 'drive-staging.ps1'
@"
. '$funcFile'
`$myLocation = '$sandbox'
`$installDir = '$installDir'
`$stagingDir = '$staging'
`$temp = '$staging\'
`$downloadFile = '$archive'
$stagingBlock
"@ | Set-Content -Path $driver -Encoding UTF8

$driverOutput = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $driver }
$driverExit = $LASTEXITCODE
$driverOutput | ForEach-Object { Write-Host "    $_" }

Assert-That -Name "the update staging sequence runs without error" -Condition ($driverExit -eq 0) `
    -Detail "exit code $driverExit"

# The restart task installs whatever staging left behind. If staging leaves no
# binary at all, the task stops the service, finds nothing, and starts the old
# one again: the update reports success and applies nothing.
# Only what is under the install directory counts: that is where the restart
# task looks, and it excludes anything the harness itself left lying around.
$survivors = @(Get-ChildItem -Path $installDir -Recurse -Filter 'proxiport*.exe' -ErrorAction SilentlyContinue)
foreach ($survivor in $survivors)
{
    Write-Measured -Name "staged binary" -Value $survivor.FullName.Substring($sandbox.Length).TrimStart('\')
}
Write-Measured -Name "staging directory still present" -Value (Test-Path -LiteralPath $staging)

Assert-That -Name "staging leaves a binary for the restart task to install" `
    -Condition ($survivors.Count -ge 1) `
    -Detail "no proxiport executable survived the staging sequence"

$taskInstallsFromStaging = $updateBody -match 'proxiport-update\\proxiport\.exe'
Assert-That -Name "the restart task no longer installs from the world-writable temp directory" `
    -Condition (-not $taskInstallsFromStaging)

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue


# ---------------------------------------------------------------------------
Write-Section "Deferred restart task is runnable"
# Invoke-Later writes a script file and registers a SYSTEM task that runs it.
# The task's own argument string has to survive back to that file -- an
# unquoted path with a space in it produces a task that is registered
# successfully and then fails at fire time, which is invisible until an update
# is attempted on a real host.

$invokeLater = $updateAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Later'
}, $true) | Select-Object -First 1

if (-not $invokeLater)
{
    throw "could not locate Invoke-Later in the rendered update script"
}

$taskSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("later-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $taskSandbox | Out-Null
$laterFuncs = Join-Path $taskSandbox 'functions.ps1'
Set-Content -Path $laterFuncs -Value $functionsBody -Encoding UTF8

$laterDriver = Join-Path $taskSandbox 'drive-later.ps1'
@"
. '$laterFuncs'
`$myLocation = '$taskSandbox'
`$installDir = "`$( `$Env:Programfiles )\proxiport"
New-Item -ItemType Directory -Force -Path `$installDir | Out-Null
$( $invokeLater.Extent.Text )
Invoke-Later -Description "Harness probe" -Delay 3600 -ScriptBlock {
    Write-Output 'harness probe body'
}
"@ | Set-Content -Path $laterDriver -Encoding UTF8

$laterOutput = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $laterDriver }
$laterExit = $LASTEXITCODE
$laterOutput | ForEach-Object { Write-Host "    $_" }

Assert-That -Name "Invoke-Later registers a task without error" -Condition ($laterExit -eq 0) `
    -Detail "exit code $laterExit"

$taskFileMatch = [regex]::Match(($laterOutput -join "`n"), '\[(?<path>[^\]]+\.ps1)\]')
Assert-That -Name "Invoke-Later reports the script file it created" -Condition $taskFileMatch.Success

if ($taskFileMatch.Success)
{
    $taskFile = $taskFileMatch.Groups['path'].Value
    $taskName = [System.IO.Path]::GetFileNameWithoutExtension($taskFile)
    Write-Measured -Name "task script file" -Value $taskFile

    try
    {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $arguments = $task.Actions[0].Arguments
        Write-Measured -Name "task action arguments" -Value $arguments

        Assert-That -Name "the task runs as SYSTEM" -Condition ($task.Principal.UserId -match 'SYSTEM')

        # Resolve the -File argument exactly as the shell would: a quoted path
        # survives spaces, a bare one stops at the first space.
        $fileArg = [regex]::Match($arguments, '(?i)-file\s+(?:"(?<quoted>[^"]+)"|(?<bare>\S+))')
        Assert-That -Name "the task action passes a -File argument" -Condition $fileArg.Success
        if ($fileArg.Success)
        {
            $resolved = if ($fileArg.Groups['quoted'].Success) { $fileArg.Groups['quoted'].Value } else { $fileArg.Groups['bare'].Value }
            Assert-That -Name "the task's -File argument resolves to the file that was created" `
                -Condition (Test-Path -LiteralPath $resolved) -Detail "resolved to '$resolved'"
        }

        Assert-That -Name "the task script contains the scheduled body" `
            -Condition ((Get-Content -Raw -LiteralPath $taskFile) -match 'harness probe body')
    }
    finally
    {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $taskFile -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath $taskSandbox -Recurse -Force -ErrorAction SilentlyContinue


# ---------------------------------------------------------------------------
Write-Section "Scripts load the way a host runs them"
# The documented Windows flow saves the script with -OutFile and then runs it
# with -File. Windows PowerShell decodes a file that carries no byte order mark
# using the system ANSI codepage, so a script that is perfectly good UTF-8 can
# still fail to load once it is on disk -- and parsing the file in-process does
# not necessarily go through the same decoding. Load it the way a host does.

foreach ($file in @('update.ps1'))
{
    $path = Join-Path $ScriptDir $file
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 0x7F) { $nonAscii++ } }
    Write-Measured -Name "$file carries a byte order mark" -Value $hasBom
    Write-Measured -Name "$file non-ASCII bytes" -Value $nonAscii

    # -h prints the usage text and exits before the script touches anything.
    $probeOutput = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path -h }
    $probeExit = $LASTEXITCODE
    $loaded = ($probeExit -eq 0)
    Write-Measured -Name "$file loads from disk and prints usage" -Value $loaded
    if (-not $loaded)
    {
        Write-Host "  script did not load; first lines of output:"
        $probeOutput | Select-Object -First 12 | ForEach-Object { Write-Host "    $_" }
        $script:Summary.Add("")
        $script:Summary.Add("> ``$file`` does not load when saved to disk and run with -File, which is the documented flow.")
    }
}


# ---------------------------------------------------------------------------
Write-Host ""
# ---------------------------------------------------------------------------
Write-Section "A fresh install can extract into its install directory"
# Everything above drives the UPDATE path. The install path had no gate at all,
# which is how a guard that refuses every fresh install reached a green run:
# Expand-Zip refused to extract when the archive sat "inside" its destination,
# and it decided that with a raw string prefix test. install.ps1 stages in
# "%ProgramFiles%\proxiport-install-tmp" and extracts into "%ProgramFiles%\proxiport",
# and the first string does begin with the second -- so the guard fired on a
# sibling directory and every new Windows agent failed to install.
#
# Runs the real Expand-Zip, lifted out of the rendered installer through its
# syntax tree, against the real pair of paths taken from the same script.

$installerFunctions = Get-RenderedSection -Content $rendered['installer.ps1'] -Section 'templates/windows/functions.ps1'

$expandZipSource = $null
if ($installerFunctions)
{
    $fnAst = [System.Management.Automation.Language.Parser]::ParseInput(
        ($installerFunctions -join "`n"), [ref]$null, [ref]$null)
    $expandZipSource = $fnAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Expand-Zip'
    }, $true) | Select-Object -First 1
}

Assert-That -Name "Expand-Zip is defined in the rendered installer" -Condition ($null -ne $expandZipSource)

if ($expandZipSource)
{
    . ([scriptblock]::Create($expandZipSource.Extent.Text))

    $installSandbox = Join-Path $Env:TEMP ("install-gate-" + [System.Guid]::NewGuid().ToString('N'))
    # Mirror the shipped shape exactly: the staging directory is a SIBLING of
    # the install directory whose name starts with the install directory's.
    $gateInstallDir = Join-Path $installSandbox 'proxiport'
    $gateStagingDir = Join-Path $installSandbox 'proxiport-install-tmp'
    New-Item -ItemType Directory -Path $gateInstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path $gateStagingDir -Force | Out-Null

    $payloadDir = Join-Path $installSandbox 'payload'
    New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $payloadDir 'proxiport.exe') -Value 'binary' -Encoding Ascii
    $gateZip = Join-Path $gateStagingDir 'proxiport_0.0.0_windows_x86_64.zip'
    Compress-Archive -Path (Join-Path $payloadDir '*') -DestinationPath $gateZip -Force

    Write-Measured -Name "archive staged at" -Value $gateZip
    Write-Measured -Name "extracting into"   -Value $gateInstallDir

    $installError = $null
    try { Expand-Zip -Path $gateZip -DestinationPath $gateInstallDir }
    catch { $installError = $_.Exception.Message }

    Assert-That -Name "a fresh install extracts from its sibling staging directory" `
        -Condition ($null -eq $installError) -Detail $installError
    Assert-That -Name "the extracted binary lands in the install directory" `
        -Condition (Test-Path -LiteralPath (Join-Path $gateInstallDir 'proxiport.exe'))

    # The guard still has to do its actual job: an archive genuinely inside its
    # own destination is deleted by the PowerShell < 5 fallback before it can be
    # read, so that must still be refused.
    $containedZip = Join-Path $gateInstallDir 'contained.zip'
    Copy-Item -LiteralPath $gateZip -Destination $containedZip -Force
    $containedError = $null
    try { Expand-Zip -Path $containedZip -DestinationPath $gateInstallDir }
    catch { $containedError = $_.Exception.Message }

    Assert-That -Name "an archive inside its own destination is still refused" `
        -Condition ($null -ne $containedError) -Detail 'the containment guard is no longer firing'

    Remove-Item -LiteralPath $installSandbox -Recurse -Force -ErrorAction SilentlyContinue
}


# ---------------------------------------------------------------------------
Write-Section "Add-ToConfig keeps the agent config a set of lines"
# Add-ToConfig used to test `$ConfigContent -NotMatch "[$block]"` with an ARRAY
# on the left. In PowerShell that is a filter, not a boolean: it returns every
# element that does not match, which for any real config is a non-empty array
# and therefore always true. So the "append the missing block" branch ran every
# time, and "$ConfigContent" flattened the whole file into one space-separated
# line. update.ps1 is the one caller, it passes a raw Get-Content array, and it
# writes the result straight back -- so a proxiport.conf, whose first line is a
# #==== banner, became a single comment. Server URL, auth credential and
# fingerprint all gone, the service restarted, and the host never reconnected:
# recoverable only with physical or RDP access.
#
# Driven against the rendered functions.ps1, so this tests what the service
# actually serves, and the function is lifted out by AST rather than by
# sourcing the whole template.
# $functionsBody is the functions.ps1 section already sliced out of the
# rendered update.ps1 above -- the same bytes the service serves.
$addToConfigSource = $null
if ($functionsBody)
{
    $fnSectionAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $functionsBody, [ref] $null, [ref] $null)
    $addToConfigSource = $fnSectionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Add-ToConfig'
    }, $true) | Select-Object -First 1
}

Assert-That -Name "Add-ToConfig is defined in the rendered functions" `
    -Condition ($null -ne $addToConfigSource)

if ($addToConfigSource)
{
    . ([scriptblock]::Create($addToConfigSource.Extent.Text))

    $originalConfig = @(
        '#=========================================================',
        '# ProxiPort agent configuration',
        '#=========================================================',
        '[client]',
        '  server = "port.example.com:443"',
        '  auth = "agent-id:agent-secret"',
        '',
        '[interpreter-aliases]',
        "#  pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'"
    )

    # Assigned the way update.ps1 assigns it: no @() wrapper, which would wrap
    # the returned array inside a second array and make this read as flattened
    # whether or not it is.
    $updatedConfig = Add-ToConfig -ConfigContent $originalConfig -Block 'interpreter-aliases' `
        -Line "bash = 'C:\Program Files\Git\bin\bash.exe'"

    Write-Measured -Name "config lines in" -Value $originalConfig.Count
    Write-Measured -Name "config lines out" -Value @($updatedConfig).Count

    Assert-That -Name "Add-ToConfig returns lines, not one flattened string" `
        -Condition ($updatedConfig -is [System.Array]) `
        -Detail "returned $( $updatedConfig.GetType().FullName )"

    Assert-That -Name "the config does not lose lines" `
        -Condition (@($updatedConfig).Count -ge $originalConfig.Count) `
        -Detail "went from $( $originalConfig.Count ) to $( @($updatedConfig).Count )"

    Assert-That -Name "the server line survives as its own line" `
        -Condition (@($updatedConfig | Where-Object { $_ -match '^\s*server\s*=' }).Count -eq 1) `
        -Detail 'the config was flattened into a single comment'

    Assert-That -Name "the auth credential survives as its own line" `
        -Condition (@($updatedConfig | Where-Object { $_ -match '^\s*auth\s*=' }).Count -eq 1) `
        -Detail 'the config was flattened into a single comment'

    Assert-That -Name "an existing block is not duplicated" `
        -Condition (@($updatedConfig | Where-Object { $_ -match '^\s*\[interpreter-aliases\]' }).Count -eq 1) `
        -Detail 'the missing-block branch fired on a block that was present'

    Assert-That -Name "the interpreter alias is actually added" `
        -Condition (@($updatedConfig | Where-Object { $_ -match '^\s*bash\s*=' }).Count -eq 1) `
        -Detail 'nothing was added, so the gates above would pass vacuously'

    # The other half: a block that genuinely is missing must be appended, once,
    # with the line beneath it and the existing lines untouched.
    $noBlockConfig = @('# banner', '[client]', '  server = "x:443"')
    $appendedConfig = Add-ToConfig -ConfigContent $noBlockConfig -Block 'interpreter-aliases' `
        -Line "bash = 'b.exe'"

    Assert-That -Name "a missing block is appended exactly once" `
        -Condition (@($appendedConfig | Where-Object { $_ -match '^\s*\[interpreter-aliases\]' }).Count -eq 1) `
        -Detail 'the block was appended zero times or more than once'

    Assert-That -Name "appending a block keeps the existing lines intact" `
        -Condition (@($appendedConfig | Where-Object { $_ -match '^\s*server\s*=' }).Count -eq 1) `
        -Detail 'the original lines were flattened'
}

# ---------------------------------------------------------------------------
Write-Section "The updater's -v switch actually pins the release"
# update_init.ps1 declared [String]$v and the rendered -h text advertised
# "-v [version] Upgrade to the specified version", but $v was referenced
# nowhere: Invoke-Download always resolved GitHub's "latest". An operator
# pinning a fleet back off a bad release got the release they were rolling
# back from, while the script printed the new version and "finished".
#
# Driven for real, with the network and checksum calls stubbed, so this
# asserts where the download points rather than that a parameter exists.
$invokeDownloadSource = $null
if ($functionsBody)
{
    $invokeDownloadSource = $fnSectionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-Download'
    }, $true) | Select-Object -First 1
}

Assert-That -Name "Invoke-Download is defined in the rendered functions" `
    -Condition ($null -ne $invokeDownloadSource)

if ($invokeDownloadSource)
{
    . ([scriptblock]::Create($invokeDownloadSource.Extent.Text))

    $script:RequestedUrl = $null
    $script:LatestWasResolved = $false
    function Get-LatestReleaseTag { $script:LatestWasResolved = $true; return 'v9.9.9' }
    function Confirm-ReleaseChecksum { param($FilePath, $AssetName, $Tag, $StagingDir) }
    function Invoke-WebRequest
    {
        param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing)
        $script:RequestedUrl = $Uri
        New-Item -ItemType File -Force -Path $OutFile | Out-Null
    }

    $pinStaging = Join-Path ([IO.Path]::GetTempPath()) ("pin-gate-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $pinStaging | Out-Null

    $null = Invoke-Download -StagingDir $pinStaging -gt '0.8.3' -Version '0.8.2'
    Write-Measured -Name "url for -v 0.8.2" -Value $script:RequestedUrl

    Assert-That -Name "-v downloads the pinned release, not latest" `
        -Condition ($script:RequestedUrl -like '*/download/v0.8.2/proxiport_0.8.2_windows_x86_64.zip') `
        -Detail "requested $( $script:RequestedUrl )"
    Assert-That -Name "-v does not consult GitHub's latest release at all" `
        -Condition (-not $script:LatestWasResolved) `
        -Detail 'Get-LatestReleaseTag was still called, so the pin is advisory only'

    # A rollback is the whole point: the pinned version is older than the
    # installed one, and must not be mistaken for "already up to date".
    Assert-That -Name "-v to an older release is not treated as up to date" `
        -Condition ($script:RequestedUrl -notlike '*up-to-date*') `
        -Detail 'the rollback was short-circuited'

    # Without -v the behaviour is unchanged: resolve latest.
    $script:RequestedUrl = $null
    $script:LatestWasResolved = $false
    $null = Invoke-Download -StagingDir $pinStaging -gt '0.0.1'
    Assert-That -Name "without -v the updater still resolves latest" `
        -Condition ($script:LatestWasResolved -and $script:RequestedUrl -like '*/download/v9.9.9/*') `
        -Detail "requested $( $script:RequestedUrl )"

    Remove-Item -LiteralPath $pinStaging -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "=== Result ==="
if ($Env:GITHUB_STEP_SUMMARY)
{
    $script:Summary -join "`n" | Add-Content -Path $Env:GITHUB_STEP_SUMMARY -Encoding UTF8
}
if ($script:Failures.Count -gt 0)
{
    Write-Host "$( $script:Failures.Count ) gate(s) failed:"
    $script:Failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host "All gates passed."
