<#
.SYNOPSIS
    Fetch the rendered client scripts from a locally started pairing service.

.DESCRIPTION
    The client scripts are assembled per request from the embedded templates,
    and the Windows variants are selected by the caller's user agent. Reading
    the template files straight off disk would therefore test something the
    service never actually serves.

    This starts the service on loopback with a throwaway configuration, fetches
    each script the way a real host does, and writes the responses to -OutDir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $OutDir,

    [int] $Port = 9099
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Matches the static-deposit code below; any 7 alphanumerics would do.
$staticCode = '0000000'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pairing-render-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$exe = Join-Path $workDir 'proxiport-pairing.exe'
Write-Host "Building the pairing service..."
& go build -o $exe ./cmd/proxiport-pairing
if ($LASTEXITCODE -ne 0)
{
    throw "go build failed with exit code $LASTEXITCODE"
}

# A rendering-only configuration. The static deposit exists precisely so the
# installer can be rendered without performing a deposit first; the values are
# placeholders and never leave this runner.
$conf = Join-Path $workDir 'pairing.conf'
@"
[server]
  address = "127.0.0.1:$Port"
  url = "http://127.0.0.1:$Port"

[static-deposit]
  code = "$staticCode"
  connect_url = "http://proxiport.example.com:8080"
  fingerprint = "2a:c4:79:04:80:ba:7c:60:05:e5:2c:49:6d:74:56:24"
  client_id = "render-only"
  password = "render-only"
"@ | Set-Content -Path $conf -Encoding UTF8

$proc = Start-Process -FilePath $exe -ArgumentList @('-c', $conf) -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $workDir 'service.out') `
    -RedirectStandardError (Join-Path $workDir 'service.err')

try
{
    # Wait for the listener rather than sleeping a fixed amount: a fixed sleep
    # is either slower than it needs to be or racy on a loaded runner.
    $base = "http://127.0.0.1:$Port"
    $ready = $false
    foreach ($attempt in 1..60)
    {
        try
        {
            Invoke-WebRequest -Uri "$base/update" -UseBasicParsing -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        }
        catch
        {
            if ($proc.HasExited)
            {
                Get-Content (Join-Path $workDir 'service.err') -ErrorAction SilentlyContinue | Write-Host
                throw "the pairing service exited before it began listening (exit code $( $proc.ExitCode ))"
            }
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $ready)
    {
        throw "the pairing service did not start listening on $base within 15 seconds"
    }

    # "PowerShell" in the user agent is what selects the Windows templates.
    $ua = 'Mozilla/5.0 (Windows NT; Windows NT 10.0) WindowsPowerShell/5.1'
    $fetches = @(
        @{ Path = "/update";            File = 'update.ps1' }
        @{ Path = "/uninstall";         File = 'uninstall.ps1' }
        @{ Path = "/$staticCode";       File = 'installer.ps1' }
    )
    foreach ($fetch in $fetches)
    {
        $target = Join-Path $OutDir $fetch.File
        $response = Invoke-WebRequest -Uri "$base$( $fetch.Path )" -UseBasicParsing -UserAgent $ua -TimeoutSec 10
        # -OutFile would be simpler but writes with a BOM on Windows PowerShell,
        # which changes the bytes the parser sees.
        [System.IO.File]::WriteAllBytes($target, $response.Content)
        Write-Host ("Rendered {0,-16} -> {1} ({2} bytes)" -f $fetch.Path, $fetch.File, (Get-Item $target).Length)
    }
}
finally
{
    if (-not $proc.HasExited)
    {
        Stop-Process -Id $proc.Id -Force
    }
}
