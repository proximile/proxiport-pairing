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
        $script:Summary.Add("- **GATE pass** — $Name")
    }
    else
    {
        Write-Host "  GATE  FAIL  $Name"
        if ($Detail) { Write-Host "              $Detail" }
        $script:Failures += "$Name$( if ($Detail) { " -- $Detail" } )"
        $script:Summary.Add("- **GATE FAIL** — $Name$( if ($Detail) { " ($Detail)" } )")
    }
}

function Write-Measured
{
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value
    )
    Write-Host "  MEAS        $Name = $Value"
    $script:Summary.Add("- MEASURED — ${Name}: ``$Value``")
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
    Write-Measured -Name "$( $pair.Label ) BUILTIN\Users rights" -Value $u.Rights
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
Write-Section "Update staging leaves the binary the restart task installs"
# Drives the updater's own extract-and-stage block, taken out of the rendered
# script rather than restated here, so this cannot drift from what ships.

$updateBody = Get-RenderedSection -Content $rendered['update.ps1'] -Section 'templates/windows/update.ps1'
$functionsBody = Get-RenderedSection -Content $rendered['update.ps1'] -Section 'templates/windows/functions.ps1'

$errors = $null
$updateAst = [System.Management.Automation.Language.Parser]::ParseInput($updateBody, [ref]$null, [ref]$errors)

$stagingIf = $updateAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -match 'isMsiInstallation'
}, $true) | Select-Object -First 1

if (-not $stagingIf -or -not $stagingIf.ElseClause)
{
    throw "could not locate the update staging branch in the rendered update script"
}
$stagingBlock = ($stagingIf.ElseClause.Statements | ForEach-Object { $_.Extent.Text }) -join "`n"

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("staging-" + [System.Guid]::NewGuid().ToString('N'))
$staging = Join-Path $sandbox 'proxiport-update'
$payload = Join-Path $sandbox 'payload'
New-Item -ItemType Directory -Force -Path $payload | Out-Null

# A real console executable, so the version probe in the staging block behaves
# the way it does against a real release archive.
Add-Type -TypeDefinition 'public static class Stub { public static void Main() { System.Console.WriteLine("version 9.9.9"); } }' `
    -OutputAssembly (Join-Path $payload 'proxiport.exe') -OutputType ConsoleApplication
'# placeholder' | Set-Content -Path (Join-Path $payload 'proxiport.example.conf')

$archive = Join-Path $sandbox 'proxiport_9.9.9_Windows_x86_64.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $archive

$funcFile = Join-Path $sandbox 'functions.ps1'
Set-Content -Path $funcFile -Value $functionsBody -Encoding UTF8

# Mirrors the script's own temp-directory creation, which sits just above the
# branch under test.
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$driver = Join-Path $sandbox 'drive-staging.ps1'
@"
. '$funcFile'
`$myLocation = '$sandbox'
`$temp = '$staging\'
`$downloadFile = '$archive'
$stagingBlock
"@ | Set-Content -Path $driver -Encoding UTF8

$driverOutput = Invoke-Native { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $driver }
$driverExit = $LASTEXITCODE
$driverOutput | ForEach-Object { Write-Host "    $_" }

Assert-That -Name "the update staging block runs without error" -Condition ($driverExit -eq 0) `
    -Detail "exit code $driverExit"

$stagedExe = Join-Path $staging 'proxiport.exe'
$stagedExists = Test-Path -LiteralPath $stagedExe

# The restart task the updater schedules installs from this path. If staging
# does not leave a binary there, the task stops the service, finds nothing, and
# starts the old binary again -- the update silently does nothing.
$taskInstallsFromStaging = $updateBody -match 'proxiport-update\\proxiport\.exe'
Assert-That -Name "the restart task installs from the staging directory" -Condition $taskInstallsFromStaging

Write-Measured -Name "staged binary present after staging completes" -Value $stagedExists
Write-Measured -Name "staging directory present after staging completes" -Value (Test-Path -LiteralPath $staging)

if (-not $stagedExists)
{
    Write-Host ""
    Write-Host "  NOTE: staging removed the binary that the restart task installs from,"
    Write-Host "        so an update applies nothing. Measured, not gated, because it"
    Write-Host "        describes current behaviour rather than intended behaviour."
    $script:Summary.Add("")
    $script:Summary.Add("> Staging removed the binary the restart task installs from, so an update applies nothing.")
}

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
Write-Host ""
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
