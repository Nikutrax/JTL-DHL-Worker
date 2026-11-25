param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'print-config.json')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    $logDir = Join-Path $PSScriptRoot 'Logs'
    if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -LiteralPath (Join-Path $logDir ("PrintAgent_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding UTF8
}

if (!(Test-Path -LiteralPath $ConfigPath)) {
    throw "Konfiguration fehlt: $ConfigPath. Bitte print-config.example.json nach print-config.json kopieren und anpassen."
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($dir in @($config.LabelPath, $config.ArchivePath, $config.ErrorPath)) {
    if ([string]::IsNullOrWhiteSpace($dir)) { throw 'Ein benoetigter Ordnerpfad ist leer.' }
    if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if (!(Test-Path -LiteralPath $config.Pdf24DocTool)) {
    throw "PDF24 DocTool nicht gefunden: $($config.Pdf24DocTool)"
}
if ([string]::IsNullOrWhiteSpace($config.PrinterName)) { throw 'PrinterName ist leer.' }

$pollSeconds = [Math]::Max(1, [int]$config.PollSeconds)
$readySeconds = [Math]::Max(0, [int]$config.FileReadySeconds)
$exclude = @($config.ExcludeNameContains | ForEach-Object { ([string]$_).ToLowerInvariant() })

Write-Log "Print-Agent gestartet. LabelPath='$($config.LabelPath)', Drucker='$($config.PrinterName)'"
Write-Log 'OTTO-Retourenlabels werden vom Worker nicht in die normale Hinweg-PDF kombiniert. Zusaetzlich werden Dateinamen mit Retoure/Return/Ruecksendung uebersprungen.'

while ($true) {
    try {
        $files = Get-ChildItem -LiteralPath $config.LabelPath -File -Filter '*.pdf' -ErrorAction Stop | Sort-Object CreationTime
        foreach ($file in $files) {
            $lowerName = $file.Name.ToLowerInvariant()
            $skip = $false
            foreach ($term in $exclude) {
                if ($term -and $lowerName.Contains($term)) { $skip = $true; break }
            }
            if ($skip) {
                Write-Log "Uebersprungen (Ausschluss): $($file.Name)" 'WARN'
                continue
            }

            if ($readySeconds -gt 0 -and ((Get-Date) - $file.LastWriteTime).TotalSeconds -lt $readySeconds) {
                continue
            }

            # Exklusiv oeffnen: so wird keine noch geschriebene Datei gedruckt.
            try {
                $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
                $stream.Close()
            } catch {
                continue
            }

            Write-Log "Drucke: $($file.Name)"
            $args = @('-shellPrint', '-printerName', [string]$config.PrinterName, $file.FullName)
            $proc = Start-Process -FilePath $config.Pdf24DocTool -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -ne 0) {
                throw "PDF24 Rueckgabecode $($proc.ExitCode) fuer $($file.Name)"
            }

            $dest = Join-Path $config.ArchivePath $file.Name
            if (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $config.ArchivePath ("{0}_{1}{2}" -f $file.BaseName, (Get-Date -Format 'yyyyMMdd_HHmmssfff'), $file.Extension)
            }
            Move-Item -LiteralPath $file.FullName -Destination $dest -Force
            Write-Log "Gedruckt und archiviert: $($file.Name)"
        }
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds $pollSeconds
}
