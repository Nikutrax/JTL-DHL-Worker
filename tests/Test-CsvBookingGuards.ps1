$ErrorActionPreference = 'Stop'
$worker = Join-Path (Split-Path -Parent $PSScriptRoot) 'JTL-DHL-Worker.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('JtlCsvTest-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $c = @{ Environment = 'Production'; ProductionEnabled = $false; AutoProductionEnabled = $false; CsvAutomationEnabled = $false }
    foreach ($key in @('StatePath','LabelPath','ImportPath','ExportPath','ProcessedPath','ErrorPath','LogPath')) {
        $c[$key] = Join-Path $root $key
        New-Item -ItemType Directory -Path $c[$key] | Out-Null
    }
    $stateDir = Join-Path $c.StatePath 'Production'
    $backupDir = Join-Path $c.ImportPath 'backup'
    New-Item -ItemType Directory -Path $stateDir,$backupDir | Out-Null
    $cfg = Join-Path $root 'config.json'
    $c | ConvertTo-Json | Set-Content -LiteralPath $cfg -Encoding UTF8

    function Invoke-TestMode {
        param([string]$Name,[string]$Arguments,[string]$Pattern,[bool]$ExpectSuccess)
        $stdout = Join-Path $root ($Name + '.out')
        $stderr = Join-Path $root ($Name + '.err')
        $argsLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $worker + '" -ConfigPath "' + $cfg + '" ' + $Arguments
        $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argsLine -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $out = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
        if ($out -notmatch $Pattern -or (($p.ExitCode -eq 0) -ne $ExpectSuccess)) {
            throw "$Name unexpected result: exit=$($p.ExitCode) $out"
        }
        Write-Host "PASS: $Name"
    }

    Invoke-TestMode 'empty' '-CheckDuplicateOnly -SpecificFile P1001' 'KEIN LOKALER BUCHUNGSNACHWEIS' $true
    Set-Content -LiteralPath (Join-Path $stateDir 'P1002.json') -Value '{"status":"DHL_BOOKING_RESERVED"}'
    Invoke-TestMode 'reserved' '-CheckDuplicateOnly -SpecificFile P1002' 'BUCHUNG GESPERRT' $true
    Set-Content -LiteralPath (Join-Path $stateDir 'P1003.json.test.tmp') -Value 'recovery'
    Invoke-TestMode 'recovery' '-CheckDuplicateOnly -SpecificFile P1003' 'BUCHUNG GESPERRT' $false
    Set-Content -LiteralPath (Join-Path $c.LabelPath 'TEST_P1004.pdf') -Value 'dummy'
    Invoke-TestMode 'label' '-CheckDuplicateOnly -SpecificFile P1004' 'Vorhandenes Label' $false
    Set-Content -LiteralPath (Join-Path $c.ImportPath 'tracking_CSV_P1005.csv') -Value 'dummy'
    Invoke-TestMode 'import' '-CheckDuplicateOnly -SpecificFile P1005' 'Vorhandene Importdatei' $false
    Set-Content -LiteralPath (Join-Path $backupDir 'tracking_TEST_P1006_test.csv') -Value 'dummy'
    Invoke-TestMode 'backup' '-CheckDuplicateOnly -SpecificFile P1006' 'Vorhandene Tracking-Sicherung' $false
    Invoke-TestMode 'disabled-automation' '-AutoProduction' 'CSV-Automatik gesperrt' $false
    Write-Host 'CSV guard tests completed; no DHL calls made.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
