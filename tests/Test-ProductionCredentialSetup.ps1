$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows PowerShell 5.1 required.'
}
$target = Join-Path (Split-Path -Parent $PSScriptRoot) 'Production-Zugang-Einrichten.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('JTL-DHL-CredentialTest-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null

# Simulated input and clipboard; real Windows DPAPI.
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($global:JtlCredentialTestInputs.Count -eq 0) { throw "Unexpected input prompt: $Prompt" }
    $next = [string]$global:JtlCredentialTestInputs.Dequeue()
    if ($AsSecureString) {
        if ($next -eq '') { return (New-Object System.Security.SecureString) }
        return (ConvertTo-SecureString $next -AsPlainText -Force)
    }
    return $next
}
function Get-Clipboard {
    [CmdletBinding()]
    param([switch]$Raw)
    if ($global:JtlCredentialTestClipboard.Count -eq 0) { throw 'Unexpected clipboard access' }
    $next = [string]$global:JtlCredentialTestClipboard.Dequeue()
    if ($next -eq '__CLIPBOARD_ERROR__') { throw 'Simulated unavailable clipboard' }
    return $next
}
function Set-Clipboard {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if ($Value -ne '') { throw 'Unexpected clipboard write' }
    $global:JtlCredentialTestClears++
}
function Test-Setup {
    param([string]$Name,[string[]]$InputValues,[string[]]$ClipboardValues,[int]$ExpectedClears,[bool]$ExpectFailure = $false)
    $global:JtlCredentialTestInputs = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($v in $InputValues) { $global:JtlCredentialTestInputs.Enqueue($v) }
    $global:JtlCredentialTestClipboard = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($v in $ClipboardValues) { $global:JtlCredentialTestClipboard.Enqueue($v) }
    $global:JtlCredentialTestClears = 0
    $path = Join-Path $root ($Name + '.json')
    $failure = $null
    try { & $target -OutputFile $path } catch { $failure = $_ }
    if ($ExpectFailure) {
        if (-not $failure -or $failure.Exception.Message -notlike '*Benutzername und Passwort*') { throw "$Name expected invalid username/password rejection" }
        if (Test-Path -LiteralPath $path) { throw "$Name unexpected credential file" }
    } else {
        if ($failure) { throw $failure }
        $raw = Get-Content -LiteralPath $path -Raw
        $saved = $raw | ConvertFrom-Json
        $expected = @{ ApiKey = 'dummy-key'; ApiSecret = 'dummy-secret'; Username = 'dummy-user'; Password = 'dummy-password' }
        if (@($saved.PSObject.Properties).Count -ne 4) { throw "$Name unexpected JSON schema" }
        foreach ($field in $expected.Keys) {
            if ($raw.Contains($expected[$field])) { throw "$Name plaintext found in JSON" }
            $decoded = ConvertTo-SecureString -String ([string]$saved.$field)
            try {
                $actual = (New-Object System.Management.Automation.PSCredential('dummy', $decoded)).GetNetworkCredential().Password
                if ($actual -cne $expected[$field]) { throw "$Name DPAPI round-trip failed for $field" }
            } finally { $decoded.Dispose(); $actual = $null }
        }
    }
    if ($global:JtlCredentialTestInputs.Count -ne 0 -or $global:JtlCredentialTestClipboard.Count -ne 0) { throw "$Name unused test inputs" }
    if ($global:JtlCredentialTestClears -ne $ExpectedClears) { throw "$Name clipboard clearing count mismatch" }
    Write-Host "PASS: $Name"
}
try {
    Test-Setup -Name 'manual' -InputValues @('M','dummy-key','J','M','dummy-secret','J','dummy-user','dummy-password') -ClipboardValues @() -ExpectedClears 0
    Test-Setup -Name 'clipboard' -InputValues @('Z','','J','J','Z','','J','N','dummy-user','dummy-password') -ClipboardValues @('  dummy-key  ','dummy-secret') -ExpectedClears 1
    Test-Setup -Name 'retry' -InputValues @('Z','','Z','','M','','M','reject-key','N','M','dummy-key','J','M','dummy-secret','J','dummy-user','dummy-password') -ClipboardValues @('__CLIPBOARD_ERROR__','bad key') -ExpectedClears 0
    Test-Setup -Name 'invalid-user' -InputValues @('M','dummy-key','J','M','dummy-secret','J','','dummy-password') -ClipboardValues @() -ExpectedClears 0 -ExpectFailure $true
    Write-Host 'All Windows credential setup tests passed.'
} finally {
    Remove-Variable JtlCredentialTestInputs,JtlCredentialTestClipboard,JtlCredentialTestClears -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
