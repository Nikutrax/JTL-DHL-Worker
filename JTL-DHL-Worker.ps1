param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once,
    [switch]$ValidateOnly,
    [switch]$ApproveProductionShipment,
    [switch]$AutoProduction,
    [string]$SpecificFile = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# v1.14 Community-Ausgabe: optionale SQL-Versandstatus-Integration ist standardmaessig AUS.
# Nur nach Pruefung der JTL-Datenbankstruktur und mit Datenbank-Backup einschalten.
function Test-ConfigEnabled {
    param([string]$Name)
    return (($script:Config.PSObject.Properties.Name -contains $Name) -and ([bool]$script:Config.$Name))
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    Write-Host $line
    if ($script:Config -and $script:Config.LogPath) {
        try {
            if (-not (Test-Path $script:Config.LogPath)) { New-Item -ItemType Directory -Path $script:Config.LogPath -Force | Out-Null }
            $logFile = Join-Path $script:Config.LogPath ("worker_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
            Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
        } catch { }
    }
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Konfiguration nicht gefunden: $ConfigPath" }
    $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    return ($json | ConvertFrom-Json)
}

function Ensure-Directories {
    $paths = @($script:Config.ExportPath, $script:Config.ImportPath, $script:Config.LabelPath, $script:Config.ProcessedPath, $script:Config.ErrorPath, $script:Config.StatePath, $script:Config.LogPath)
    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

function Assert-Config {
    if ($script:Config.Environment -notin @('Sandbox','Production')) { throw "Environment muss Sandbox oder Production sein." }

    if ($script:Config.Environment -eq 'Production') {
        if ($ValidateOnly) {
            if (-not [bool]$script:Config.ProductionValidationEnabled) {
                throw "Production-Validierung ist in config.json gesperrt."
            }
        } else {
            if (-not [bool]$script:Config.ProductionEnabled) {
                throw "ECHTVERSAND IST GESPERRT. ProductionEnabled steht auf false."
            }

            if ($AutoProduction) {
                if (-not ($script:Config.PSObject.Properties.Name -contains 'AutoProductionEnabled') -or -not [bool]$script:Config.AutoProductionEnabled) {
                    throw "AUTOMATISCHER PRODUCTION-BETRIEB IST GESPERRT. AutoProductionEnabled steht nicht auf true."
                }
            } else {
                if (-not $ApproveProductionShipment) {
                    throw "ECHTVERSAND benötigt zusätzlich den Startparameter -ApproveProductionShipment."
                }
                if ([string]::IsNullOrWhiteSpace($SpecificFile)) {
                    throw "Manueller ECHTVERSAND ist nur mit -SpecificFile erlaubt."
                }
            }
        }
    }

    if ($script:Config.Environment -eq 'Sandbox') {
        if ([string]::IsNullOrWhiteSpace($script:Config.ApiKey) -or $script:Config.ApiKey -like 'HIER_*') {
            throw "Bitte Sandbox ApiKey in config.json eintragen."
        }
        if ($script:Config.AuthMode -eq 'OAuth2') {
            if ([string]::IsNullOrWhiteSpace($script:Config.ApiSecret) -or $script:Config.ApiSecret -like 'HIER_*') {
                throw "Bitte Sandbox ApiSecret in config.json eintragen."
            }
        }
    } else {
        if (-not (Test-Path (Join-Path -Path $PSScriptRoot -ChildPath ([string]$script:Config.ProductionCredentialFile)))) {
            throw "Verschlüsselte Production-Zugangsdaten fehlen. Bitte zuerst Production-Zugang-Einrichten.cmd starten."
        }
    }
}

function Get-BaseUrl {
    if ($script:Config.Environment -eq 'Sandbox') { return 'https://api-sandbox.dhl.com/parcel/de/shipping/v2' }
    return 'https://api-eu.dhl.com/parcel/de/shipping/v2'
}

function Get-TokenUrl {
    if ($script:Config.Environment -eq 'Sandbox') { return 'https://api-sandbox.dhl.com/parcel/de/account/auth/ropc/v1/token' }
    return 'https://api-eu.dhl.com/parcel/de/account/auth/ropc/v1/token'
}


function Get-ProductionCredentials {
    $path = Join-Path -Path $PSScriptRoot -ChildPath ([string]$script:Config.ProductionCredentialFile)
    if (-not (Test-Path $path)) { throw "Production-Credentials fehlen: $path" }
    $enc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

    function Unprotect([string]$Value) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $secure = $Value | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }

    return @{
        ApiKey    = Unprotect ([string]$enc.ApiKey)
        ApiSecret = Unprotect ([string]$enc.ApiSecret)
        Username  = Unprotect ([string]$enc.Username)
        Password  = Unprotect ([string]$enc.Password)
    }
}

function Get-AuthHeaders {
    if ($script:Config.Environment -eq 'Production') {
        $cred = Get-ProductionCredentials
        $tokenBody = @{
            grant_type    = 'password'
            username      = [string]$cred.Username
            password      = [string]$cred.Password
            client_id     = [string]$cred.ApiKey
            client_secret = [string]$cred.ApiSecret
        }
        try {
            $token = Invoke-RestMethod -Method Post -Uri (Get-TokenUrl) -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
        } finally {
            $tokenBody.password = $null
            $cred.Password = $null
            $cred.ApiSecret = $null
        }
        if (-not $token.access_token) { throw 'DHL Production OAuth2: Kein access_token erhalten.' }
        return @{
            'Authorization'   = ('Bearer ' + [string]$token.access_token)
            'Accept'          = 'application/json'
            'Accept-Language' = 'de-DE'
        }
    }

    # Sandbox
    $tokenBody = @{
        grant_type    = 'password'
        username      = [string]$script:Config.Username
        password      = [string]$script:Config.Password
        client_id     = [string]$script:Config.ApiKey
        client_secret = [string]$script:Config.ApiSecret
    }
    $token = Invoke-RestMethod -Method Post -Uri (Get-TokenUrl) -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
    if (-not $token.access_token) { throw 'DHL Sandbox OAuth2: Kein access_token erhalten.' }
    return @{
        'Authorization'   = ('Bearer ' + [string]$token.access_token)
        'Accept'          = 'application/json'
        'Accept-Language' = 'de-DE'
    }
}

function Get-HttpErrorText {
    param($ErrorRecord)

    $statusText = $null
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            try {
                $code = [int]$resp.StatusCode
                $statusText = "HTTP $code $($resp.StatusDescription)"
            } catch { }
        }
    } catch { }

    $body = $null
    try {
        if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
            $body = [string]$ErrorRecord.ErrorDetails.Message
        }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($body)) {
        try {
            $resp = $ErrorRecord.Exception.Response
            if ($resp) {
                $stream = $resp.GetResponseStream()
                if ($stream) {
                    $reader = New-Object IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            }
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        try { $body = [string]$ErrorRecord.Exception.Message } catch { }
    }

    # DHL liefert technische Fehler teils in abweichenden JSON-Strukturen.
    # Wenn möglich, machen wir die JSON-Antwort kompakt lesbar, behalten aber immer den Rohtext.
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        try {
            $obj = $body | ConvertFrom-Json
            $body = $obj | ConvertTo-Json -Depth 12 -Compress
        } catch { }
    }

    if ($statusText -and $body) { return "$statusText | $body" }
    if ($statusText) { return $statusText }
    if ($body) { return $body }
    return 'Unbekannter HTTP-Fehler ohne Antworttext.'
}

function Save-DebugText {
    param([string]$Prefix, [string]$Text)
    try {
        if (-not (Test-Path $script:Config.LogPath)) { New-Item -ItemType Directory -Path $script:Config.LogPath -Force | Out-Null }
        $name = "{0}_{1}.txt" -f $Prefix,(Get-Date -Format 'yyyyMMdd_HHmmssfff')
        $path = Join-Path $script:Config.LogPath $name
        [IO.File]::WriteAllText($path, [string]$Text, (New-Object Text.UTF8Encoding($true)))
        return $path
    } catch { return $null }
}

function Normalize-Country2 {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { throw 'LandISO fehlt.' }
    $c = $Code.Trim().ToUpperInvariant()
    if ($c.Length -eq 2) { return $c }
    if ($c.Length -eq 3) {
        try {
            foreach ($culture in [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures)) {
                try {
                    $r = New-Object Globalization.RegionInfo($culture.Name)
                    if ($r.ThreeLetterISORegionName -eq $c) { return $r.TwoLetterISORegionName }
                } catch {}
            }
        } catch {}
    }
    throw "LandISO '$Code' konnte nicht in einen zweistelligen ISO-Code umgewandelt werden."
}

function Convert-CountryToAlpha3 {
    param([string]$Code)
    $c2 = Normalize-Country2 $Code
    try {
        $region = New-Object Globalization.RegionInfo($c2)
        return $region.ThreeLetterISORegionName.ToUpperInvariant()
    } catch {
        throw "LandISO '$Code' ist unbekannt."
    }
}

function Test-IsEuCountry {
    param([string]$Code)
    $c = Normalize-Country2 $Code
    # EU-27. Nicht-EU (z.B. CH, GB, NO) bleibt bewusst manuell.
    $eu = @(
        'AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','GR','DE','HU','IE',
        'IT','LV','LT','LU','MT','NL','PL','PT','RO','SK','SI','ES','SE'
    )
    return ($c -in $eu)
}

function Convert-WeightKg {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Gewicht fehlt.' }
    $normalized = $Text.Trim().Replace(',', '.')
    $value = 0.0
    if (-not [double]::TryParse($normalized, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw "Gewicht '$Text' ist ungültig."
    }
    if ($value -le 0) { throw 'Gewicht muss größer als 0 kg sein.' }
    return $value
}

function Get-ProductInfo {
    param([string]$Versandart, [double]$WeightKg, [string]$LandISO)

    if ([string]::IsNullOrWhiteSpace($Versandart)) {
        throw 'Versandart fehlt in der JTL-CSV.'
    }

    $name = $Versandart.Trim()
    $country2 = Normalize-Country2 $LandISO

    switch -CaseSensitive ($name) {

        'Versicherter Versand DHL' {
            if ($country2 -ne 'DE') {
                throw "Versandart 'Versicherter Versand DHL' ist nur für Deutschland vorgesehen. Ziel: $country2."
            }
            if ($WeightKg -gt 31.5) {
                throw "DHL Paket DE darf höchstens 31,5 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V01PAK'
                Name    = 'DHL Paket DE'
                Country = $country2
                IsOtto  = $false
            }
        }

        'DHL Kleinpaket' {
            if ($country2 -ne 'DE') {
                throw "Versandart 'DHL Kleinpaket' ist nur für Deutschland vorgesehen. Ziel: $country2."
            }
            if ($WeightKg -gt 1.0) {
                throw "DHL Kleinpaket darf höchstens 1,0 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V62KP'
                Name    = 'DHL Kleinpaket'
                Country = $country2
                IsOtto  = $false
            }
        }

        'Versicherter Versand DHL EU' {
            if ($country2 -eq 'DE') {
                throw "Versandart 'Versicherter Versand DHL EU' ist für EU-Ausland gedacht, Ziel ist aber Deutschland."
            }
            if (-not (Test-IsEuCountry $country2)) {
                throw "Versandart 'Versicherter Versand DHL EU' wird nur für EU-Länder automatisch gebucht. Ziel '$country2' bleibt für Zoll/International bewusst manuell."
            }
            if ($WeightKg -gt 31.5) {
                throw "DHL Paket International darf in diesem Worker höchstens 31,5 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V53WPAK'
                Name    = 'DHL Paket International'
                Country = $country2
                IsOtto  = $false
            }
        }

        'DHL Warenpost International' {
            if ($country2 -eq 'DE') {
                throw "Versandart 'DHL Warenpost International' ist nur für Auslandssendungen vorgesehen. Ziel: $country2."
            }
            if (-not (Test-IsEuCountry $country2)) {
                throw "DHL Warenpost International ist in dieser Worker-Version nur für EU-Ausland freigegeben. Für Ziel '$country2' fehlen im CSV noch die erforderlichen Zollpositionsdaten."
            }
            if ($WeightKg -gt 1.0) {
                throw "DHL Warenpost International darf höchstens 1,0 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V66WPI'
                Name    = 'DHL Warenpost International Premium'
                Country = $country2
                IsOtto  = $false
            }
        }

        'Warenpost International' {
            if ($country2 -eq 'DE') {
                throw "Versandart 'Warenpost International' ist nur für Auslandssendungen vorgesehen. Ziel: $country2."
            }
            if (-not (Test-IsEuCountry $country2)) {
                throw "DHL Warenpost International ist in dieser Worker-Version nur für EU-Ausland freigegeben. Für Ziel '$country2' fehlen im CSV noch die erforderlichen Zollpositionsdaten."
            }
            if ($WeightKg -gt 1.0) {
                throw "DHL Warenpost International darf höchstens 1,0 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V66WPI'
                Name    = 'DHL Warenpost International Premium'
                Country = $country2
                IsOtto  = $false
            }
        }

        'DHL Otto' {
            if ($country2 -ne 'DE') {
                throw "Versandart 'DHL Otto' ist in diesem Worker nur für Deutschland vorgesehen. Ziel: $country2."
            }
            if ($WeightKg -gt 31.5) {
                throw "DHL Paket DE darf höchstens 31,5 kg wiegen. CSV: $WeightKg kg."
            }
            return @{
                Product = 'V01PAK'
                Name    = 'DHL Paket DE + OTTO Retoure'
                Country = $country2
                IsOtto  = $true
            }
        }

        default {
            throw "Unbekannte Versandart '$Versandart'. Automatisch erlaubt sind nur: 'Versicherter Versand DHL', 'DHL Kleinpaket', 'Versicherter Versand DHL EU', 'DHL Warenpost International', 'Warenpost International', 'DHL Otto'."
        }
    }
}

function Get-BillingNumber {
    param([string]$Product)
    if ($script:Config.Environment -eq 'Sandbox') {
        $value = $script:Config.SandboxBilling.$Product
    } else {
        $value = $script:Config.ProductionBilling.$Product
    }
    if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "Keine Abrechnungsnummer für $Product konfiguriert." }
    return [string]$value
}


function Get-OttoReturnBillingNumber {
    if ($script:Config.PSObject.Properties['OttoReturnBillingNumber']) {
        $v = [string]$script:Config.OttoReturnBillingNumber
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    throw 'OttoReturnBillingNumber fehlt in config.json. Keine feste Abrechnungsnummer hinterlegt.'
}

function Get-OttoReturnAddress {
    if ($script:Config.PSObject.Properties['OttoReturnAddress'] -and $script:Config.OttoReturnAddress) {
        $a = $script:Config.OttoReturnAddress
        return [ordered]@{
            name1         = [string]$a.name1
            addressStreet = [string]$a.addressStreet
            addressHouse  = [string]$a.addressHouse
            postalCode    = [string]$a.postalCode
            city          = [string]$a.city
            country       = [string]$a.country
        }
    }
    throw 'OttoReturnAddress fehlt in config.json. Keine feste Retourenadresse hinterlegt.'
}

function Get-JtlSqlServer {
    if ($script:Config.PSObject.Properties['JtlSqlServer']) {
        $v = [string]$script:Config.JtlSqlServer
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return 'localhost\JTLWAWI'
}

function Get-JtlDatabase {
    if ($script:Config.PSObject.Properties['JtlDatabase']) {
        $v = [string]$script:Config.JtlDatabase
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return 'Mandant_1'
}

function Get-PaketIdFromRef {
    param([string]$PaketRef)
    if ([string]::IsNullOrWhiteSpace($PaketRef)) { throw 'PaketRef fehlt.' }
    $m = [regex]::Match($PaketRef.Trim(), '^P?(\d+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { throw "PaketRef '$PaketRef' hat kein erwartetes Format P1234." }
    return [int]$m.Groups[1].Value
}

function Open-JtlSqlConnection {
    Add-Type -AssemblyName System.Data
    $server = Get-JtlSqlServer
    $db = Get-JtlDatabase
    $cs = "Server=$server;Database=$db;Integrated Security=True;TrustServerCertificate=True;Application Name=JTL DHL Community Worker;"
    $cn = New-Object System.Data.SqlClient.SqlConnection $cs
    $cn.Open()
    return $cn
}

function Assert-JtlTrackingTarget {
    param(
        [string]$PaketRef,
        [string]$Lieferschein,
        [string]$ExpectedVersandart,
        [bool]$NeedsReturnTracking
    )

    $kVersand = Get-PaketIdFromRef $PaketRef
    $cn = Open-JtlSqlConnection
    try {
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = @"
SELECT
    v.kVersand,
    l.cLieferscheinNr,
    va.cName AS Versandart,
    v.cIdentCode,
    v.cEnclosedReturnIdentCode
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
LEFT JOIN dbo.tVersandArt va ON va.kVersandArt = v.kVersandArt
WHERE v.kVersand = @kVersand;
"@
        [void]$cmd.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $cmd.Parameters["@kVersand"].Value = $kVersand

        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)

        if ($dt.Rows.Count -ne 1) {
            throw "JTL-Sicherheitsabbruch: PaketRef $PaketRef entspricht nicht exakt einem tVersand-Datensatz."
        }

        $r = $dt.Rows[0]
        if ([string]$r.cLieferscheinNr -ne $Lieferschein) {
            throw "JTL-Sicherheitsabbruch: PaketRef $PaketRef gehört in JTL zu Lieferschein '$($r.cLieferscheinNr)', CSV meldet '$Lieferschein'."
        }
        if ([string]$r.Versandart -ne $ExpectedVersandart) {
            throw "JTL-Sicherheitsabbruch: JTL-Versandart ist '$($r.Versandart)' statt '$ExpectedVersandart'."
        }

        $outNo = if ($r.cIdentCode -eq [DBNull]::Value) { '' } else { [string]$r.cIdentCode }
        if (-not [string]::IsNullOrWhiteSpace($outNo)) {
            throw "JTL-Sicherheitsabbruch: JTL enthält für $PaketRef bereits Hinweg-Tracking '$outNo'. Keine neue DHL-Buchung."
        }

        if ($NeedsReturnTracking) {
            $retNo = if ($r.cEnclosedReturnIdentCode -eq [DBNull]::Value) { '' } else { [string]$r.cEnclosedReturnIdentCode }
            if (-not [string]::IsNullOrWhiteSpace($retNo)) {
                throw "JTL-Sicherheitsabbruch: JTL enthält für $PaketRef bereits Retouren-Tracking '$retNo'. Keine neue DHL-Buchung."
            }
        }

        return $kVersand
    }
    finally {
        $cn.Close()
    }
}

function Write-JtlTracking {
    param(
        [string]$PaketRef,
        [string]$Lieferschein,
        [string]$ExpectedVersandart,
        [string]$Tracking,
        [string]$ReturnTracking = ''
    )

    $kVersand = Get-PaketIdFromRef $PaketRef
    $hasReturn = -not [string]::IsNullOrWhiteSpace($ReturnTracking)

    $cn = Open-JtlSqlConnection
    $tx = $cn.BeginTransaction()
    try {
        $cmd = $cn.CreateCommand()
        $cmd.Transaction = $tx

        if ($hasReturn) {
            $cmd.CommandText = @"
UPDATE v
SET
    v.cIdentCode = @Tracking,
    v.cEnclosedReturnIdentCode = @ReturnTracking
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
LEFT JOIN dbo.tVersandArt va ON va.kVersandArt = v.kVersandArt
WHERE v.kVersand = @kVersand
  AND l.cLieferscheinNr = @Lieferschein
  AND va.cName = @Versandart
  AND (v.cIdentCode IS NULL OR LTRIM(RTRIM(v.cIdentCode)) = '')
  AND (v.cEnclosedReturnIdentCode IS NULL OR LTRIM(RTRIM(v.cEnclosedReturnIdentCode)) = '');
"@
        } else {
            $cmd.CommandText = @"
UPDATE v
SET
    v.cIdentCode = @Tracking
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
LEFT JOIN dbo.tVersandArt va ON va.kVersandArt = v.kVersandArt
WHERE v.kVersand = @kVersand
  AND l.cLieferscheinNr = @Lieferschein
  AND va.cName = @Versandart
  AND (v.cIdentCode IS NULL OR LTRIM(RTRIM(v.cIdentCode)) = '');
"@
        }

        [void]$cmd.Parameters.Add("@Tracking",[Data.SqlDbType]::NVarChar,255)
        [void]$cmd.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        [void]$cmd.Parameters.Add("@Lieferschein",[Data.SqlDbType]::NVarChar,255)
        [void]$cmd.Parameters.Add("@Versandart",[Data.SqlDbType]::NVarChar,255)

        $cmd.Parameters["@Tracking"].Value = $Tracking
        $cmd.Parameters["@kVersand"].Value = $kVersand
        $cmd.Parameters["@Lieferschein"].Value = $Lieferschein
        $cmd.Parameters["@Versandart"].Value = $ExpectedVersandart

        if ($hasReturn) {
            [void]$cmd.Parameters.Add("@ReturnTracking",[Data.SqlDbType]::NVarChar,255)
            $cmd.Parameters["@ReturnTracking"].Value = $ReturnTracking
        }

        $affected = $cmd.ExecuteNonQuery()
        if ($affected -ne 1) {
            throw "JTL-Tracking-Update hat $affected Zeilen getroffen; erwartet 1."
        }

        $check = $cn.CreateCommand()
        $check.Transaction = $tx
        $check.CommandText = @"
SELECT cIdentCode,cEnclosedReturnIdentCode
FROM dbo.tVersand
WHERE kVersand=@kVersand;
"@
        [void]$check.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $check.Parameters["@kVersand"].Value = $kVersand

        $reader = $check.ExecuteReader()
        if (-not $reader.Read()) { throw 'JTL-Kontrolle: Datensatz nicht mehr vorhanden.' }

        $dbTracking = if ($reader["cIdentCode"] -eq [DBNull]::Value) { '' } else { [string]$reader["cIdentCode"] }
        $dbReturn = if ($reader["cEnclosedReturnIdentCode"] -eq [DBNull]::Value) { '' } else { [string]$reader["cEnclosedReturnIdentCode"] }
        $reader.Close()

        if ($dbTracking -ne $Tracking) {
            throw 'JTL-Kontrolle: Hinweg-Tracking stimmt nach UPDATE nicht.'
        }
        if ($hasReturn -and $dbReturn -ne $ReturnTracking) {
            throw 'JTL-Kontrolle: Retouren-Tracking stimmt nach UPDATE nicht.'
        }

        # Versandzeitpunkt sicherstellen und anschließend identisch in die Bestellung übernehmen.
        # Falls tVersand.dVersendet bereits gesetzt ist, bleibt der vorhandene JTL-Zeitpunkt erhalten.
        # Falls es noch NULL ist, setzt der Worker jetzt den aktuellen SQL-Server-Zeitpunkt.
        $shipDateUpdate = $cn.CreateCommand()
        $shipDateUpdate.Transaction = $tx
        $shipDateUpdate.CommandText = @"
UPDATE dbo.tVersand
SET dVersendet = GETDATE()
WHERE kVersand = @kVersand
  AND dVersendet IS NULL;
"@
        [void]$shipDateUpdate.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $shipDateUpdate.Parameters["@kVersand"].Value = $kVersand
        $shipDateAffected = $shipDateUpdate.ExecuteNonQuery()
        if ($shipDateAffected -gt 1) {
            throw "JTL-dVersendet-Update hat $shipDateAffected Versanddatensätze getroffen; erwartet maximal 1."
        }

        $dateUpdate = $cn.CreateCommand()
        $dateUpdate.Transaction = $tx
        $dateUpdate.CommandText = @"
UPDATE b
SET b.dVersandt = v.dVersendet
FROM dbo.tBestellung b
JOIN dbo.tLieferschein l ON l.kBestellung = b.kBestellung
JOIN dbo.tVersand v ON v.kLieferschein = l.kLieferschein
WHERE v.kVersand = @kVersand
  AND v.dVersendet IS NOT NULL
  AND b.dVersandt IS NULL;
"@
        [void]$dateUpdate.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $dateUpdate.Parameters["@kVersand"].Value = $kVersand
        $dateAffected = $dateUpdate.ExecuteNonQuery()
        if ($dateAffected -gt 1) {
            throw "JTL-Versanddatum-Update hat $dateAffected Bestellungen getroffen; erwartet maximal 1."
        }

        $dateCheck = $cn.CreateCommand()
        $dateCheck.Transaction = $tx
        $dateCheck.CommandText = @"
SELECT TOP 1
    v.dVersendet,
    b.dVersandt
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
JOIN dbo.tBestellung b ON b.kBestellung = l.kBestellung
WHERE v.kVersand = @kVersand;
"@
        [void]$dateCheck.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $dateCheck.Parameters["@kVersand"].Value = $kVersand

        $dateReader = $dateCheck.ExecuteReader()
        if (-not $dateReader.Read()) {
            $dateReader.Close()
            throw 'JTL-Kontrolle Versanddatum: Bestellung/Lieferschein nicht gefunden.'
        }

        $dbVersendet = if ($dateReader["dVersendet"] -eq [DBNull]::Value) { $null } else { [datetime]$dateReader["dVersendet"] }
        $dbVersandt = if ($dateReader["dVersandt"] -eq [DBNull]::Value) { $null } else { [datetime]$dateReader["dVersandt"] }
        $dateReader.Close()

        if ($null -eq $dbVersendet) {
            throw 'JTL-Kontrolle Versanddatum: tVersand.dVersendet ist nach dem Update unerwartet leer.'
        }
        if ($null -eq $dbVersandt -or $dbVersandt -ne $dbVersendet) {
            throw 'JTL-Kontrolle Versanddatum: tBestellung.dVersandt wurde nicht korrekt aus tVersand.dVersendet übernommen.'
        }

        if (Test-ConfigEnabled 'EnableExperimentalShippingStatusSql') {
        # Versandstatus fuer Shop/eBay/Amazon/weitere Verkaufskanaele zur Uebertragung vormerken.
        # Referenz: SQL-Profiler-Mitschnitt vom 05.10.2026 beim manuellen JTL-Befehl
        # "Versandstatus an Onlineshop/eBay/Amazon senden".
        # WICHTIG: kPlattform wird aus Verkauf.tAuftrag uebernommen.
        # Plattform-IDs sind installationsabhaengig. Amazon-ID wird nur aus der Konfiguration gelesen.
        # kShop darf bei Plattformen wie Amazon/eBay NULL sein.

        # Auftrag/Plattform/Lieferschein fuer Queue und Log eindeutig ermitteln.
        $statusInfoCmd = $cn.CreateCommand()
        $statusInfoCmd.Transaction = $tx
        $statusInfoCmd.CommandText = @"
SELECT TOP 1
    a.cAuftragsNr,
    a.kShop,
    ISNULL(a.kPlattform, 0) AS kPlattform,
    l.kLieferschein
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
JOIN Verkauf.tAuftrag a ON a.kAuftrag = l.kBestellung
WHERE v.kVersand = @kVersand;
"@
        [void]$statusInfoCmd.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
        $statusInfoCmd.Parameters["@kVersand"].Value = $kVersand

        $statusReader = $statusInfoCmd.ExecuteReader()
        if (-not $statusReader.Read()) {
            $statusReader.Close()
            throw 'Versandstatus-Queue: Auftrag/Plattform/Lieferschein konnte nicht ermittelt werden.'
        }
        $queueAuftrag = if ($statusReader["cAuftragsNr"] -eq [DBNull]::Value) { '' } else { [string]$statusReader["cAuftragsNr"] }
        $queueShop = if ($statusReader["kShop"] -eq [DBNull]::Value) { $null } else { [int]$statusReader["kShop"] }
        $queuePlattform = [int]$statusReader["kPlattform"]
        $queueLieferschein = [int]$statusReader["kLieferschein"]
        $statusReader.Close()

        if ($queuePlattform -le 0) {
            Write-Log "WARNUNG Versandstatus: Plattform ist 0/leer. Auftrag=$queueAuftrag Lieferschein=$queueLieferschein" 'WARN'
        }

        $amazonHandled = $false
        $queueAffected = 0
        $scxAffected = 0

        $amazonPlatformId = 0
        if ($script:Config.PSObject.Properties.Name -contains 'AmazonPlatformId') {
            $amazonPlatformId = [int]$script:Config.AmazonPlatformId
        }
        if ($amazonPlatformId -gt 0 -and $queuePlattform -eq $amazonPlatformId) {
            # Amazon verwendet in diesem Mandanten NICHT die allgemeine tQueue fuer die Versandmeldung.
            # Referenz: SQL-Profiler 05.10.2026, Auftrag 4952 / Lieferschein 3133.
            # JTL schreibt pf_amazon_bestellung_versand, setzt pf_amazon_bestellung.nStatus=25
            # und aktualisiert die Amazon-Position ueber Amazon.spAmazonPosAendern.
            $amazonInfoCmd = $cn.CreateCommand()
            $amazonInfoCmd.Transaction = $tx
            $amazonInfoCmd.CommandText = @"
DECLARE @ExternalOrder nvarchar(255);
SELECT TOP 1 @ExternalOrder = a.cExterneAuftragsnummer
FROM dbo.tVersand v
JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
JOIN Verkauf.tAuftrag a ON a.kAuftrag = l.kBestellung
WHERE v.kVersand = @kVersand;

DECLARE @OrderColumn sysname;
SELECT TOP 1 @OrderColumn = c.name
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'dbo'
  AND t.name = N'pf_amazon_bestellung'
  AND c.name IN (N'cAmazonOrderId',N'cAmazonOrderID',N'cOrderId',N'cOrderID',N'cBestellNr')
ORDER BY CASE c.name
    WHEN N'cAmazonOrderId' THEN 1
    WHEN N'cAmazonOrderID' THEN 2
    WHEN N'cOrderId' THEN 3
    WHEN N'cOrderID' THEN 4
    ELSE 5 END;

IF @OrderColumn IS NULL
    THROW 51000, 'Amazon: Keine bekannte Order-ID-Spalte in pf_amazon_bestellung gefunden.', 1;

DECLARE @sql nvarchar(max) =
    N'SELECT TOP 1 b.kAmazonBestellung, @ExternalOrderOut AS cExternalOrder '
  + N'FROM dbo.pf_amazon_bestellung b WHERE CONVERT(nvarchar(255), b.' + QUOTENAME(@OrderColumn) + N') = @ExternalOrderIn;';
EXEC sp_executesql @sql,
    N'@ExternalOrderIn nvarchar(255), @ExternalOrderOut nvarchar(255)',
    @ExternalOrderIn=@ExternalOrder, @ExternalOrderOut=@ExternalOrder;
"@
            [void]$amazonInfoCmd.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
            $amazonInfoCmd.Parameters["@kVersand"].Value = $kVersand

            $amazonReader = $amazonInfoCmd.ExecuteReader()
            if (-not $amazonReader.Read()) {
                $amazonReader.Close()
                throw "Amazon-Versandstatus: Amazon-Bestellung fuer Auftrag=$queueAuftrag / externe Bestellnummer nicht gefunden."
            }
            $amazonBestellung = [int]$amazonReader["kAmazonBestellung"]
            $amazonExternalOrder = if ($amazonReader["cExternalOrder"] -eq [DBNull]::Value) { '' } else { [string]$amazonReader["cExternalOrder"] }
            $amazonReader.Close()

            # Sicherheitsregel v1.12: Nur eindeutig einpositionige Amazon-Auftraege automatisch melden.
            # Mehrpositions-/Teillieferungen werden nicht geraten, sondern klar abgebrochen.
            $amazonPosCmd = $cn.CreateCommand()
            $amazonPosCmd.Transaction = $tx
            $amazonPosCmd.CommandText = @"
SELECT
    COUNT(*) AS PosCount,
    MIN(kAmazonBestellungPos) AS kAmazonBestellungPos
FROM dbo.pf_amazon_bestellungpos
WHERE kAmazonBestellung = @kAmazonBestellung;
"@
            [void]$amazonPosCmd.Parameters.Add("@kAmazonBestellung",[Data.SqlDbType]::Int)
            $amazonPosCmd.Parameters["@kAmazonBestellung"].Value = $amazonBestellung
            $amazonPosReader = $amazonPosCmd.ExecuteReader()
            [void]$amazonPosReader.Read()
            $amazonPosCount = [int]$amazonPosReader["PosCount"]
            $amazonBestellungPos = if ($amazonPosReader["kAmazonBestellungPos"] -eq [DBNull]::Value) { 0 } else { [int]$amazonPosReader["kAmazonBestellungPos"] }
            $amazonPosReader.Close()

            if ($amazonPosCount -ne 1 -or $amazonBestellungPos -le 0) {
                throw "Amazon-Versandstatus: Auftrag=$queueAuftrag hat $amazonPosCount Amazon-Positionen. v1.12 meldet aus Sicherheitsgruenden nur eindeutige Einpositions-Auftraege automatisch."
            }

            $amazonShipCmd = $cn.CreateCommand()
            $amazonShipCmd.Transaction = $tx
            $amazonShipCmd.CommandText = @"
IF EXISTS (
    SELECT 1 FROM dbo.pf_amazon_bestellung_versand
    WHERE kAmazonBestellungPos = @kAmazonBestellungPos
      AND kLieferschein = @kLieferschein
)
BEGIN
    -- Bereits angelegt: keinen Doppel-Datensatz erzeugen. Fuer erneute Verarbeitung freigeben.
    UPDATE dbo.pf_amazon_bestellung_versand
    SET cCarrierCode = N'DHL',
        cTrackingNumber = @Tracking,
        cShipMethod = N'Paket',
        dShipDate = @ShipDate,
        dBearbeitet = NULL
    WHERE kAmazonBestellungPos = @kAmazonBestellungPos
      AND kLieferschein = @kLieferschein;
END
ELSE
BEGIN
    INSERT INTO dbo.pf_amazon_bestellung_versand
        (kAmazonBestellungPos, kLieferschein, nQuantity, kBenutzer,
         cCarrierCode, cCarrierName, cTrackingNumber, cShipMethod,
         dShipDate, dBearbeitet,
         cShipFromAddressName, cShipFromAddressLine1, cShipFromAddressLine2,
         cShipFromAddressLine3, cShipFromAddressCity, cShipFromAddressCounty,
         cShipFromAddressStateOrRegion, cShipFromPostalcode, cShipFromCountrycode)
    SELECT
         p.kAmazonBestellungPos,
         @kLieferschein,
         p.nQuantityPurchased,
         2,
         N'DHL', N'', @Tracking, N'Paket',
         @ShipDate, NULL,
         N'',N'',N'',N'',N'',N'',N'',N'',N''
    FROM dbo.pf_amazon_bestellungpos p
    WHERE p.kAmazonBestellungPos = @kAmazonBestellungPos;
END;

UPDATE dbo.pf_amazon_bestellung
SET nStatus = 25
WHERE kAmazonBestellung = @kAmazonBestellung
  AND cOrderStatus NOT IN (N'Shipped', N'PartiallyShipped', N'Canceled');

DECLARE
    @cArtNr nvarchar(100),
    @cName nvarchar(255),
    @nQuantityPurchased int,
    @fItemPrice decimal(18,6),
    @fItemTax decimal(18,6),
    @fShippingPrice decimal(18,6),
    @fShippingTax decimal(18,6),
    @cOrderItemId nvarchar(30),
    @cCarrier nvarchar(20),
    @cTrackingNumber nvarchar(50),
    @dEstimatedArrivalDate datetime,
    @cFulfillmentCenterId nvarchar(20),
    @cFullfillmentChannel nvarchar(20),
    @cMerchantOrderItemid nvarchar(50),
    @nErrorCode int,
    @cErrorMessage nvarchar(2000),
    @dErrorErstellt datetime,
    @fGeschenkverpackungKosten decimal(18,6),
    @cGeschenkverpackungTyp nvarchar(50),
    @cGrusstext nvarchar(255),
    @nGeschenk tinyint,
    @kFulfillmentAuftragPos int,
    @cCustomUrl nvarchar(255),
    @cCustomJson nvarchar(max),
    @cArchiveUrl nvarchar(512),
    @cShipmentItemId nvarchar(20);

SELECT
    @cArtNr = ISNULL(cArtNr,N''),
    @cName = ISNULL(cName,N''),
    @nQuantityPurchased = ISNULL(nQuantityPurchased,0),
    @fItemPrice = ISNULL(fItemPrice,0),
    @fItemTax = ISNULL(fItemTax,0),
    @fShippingPrice = ISNULL(fShippingPrice,0),
    @fShippingTax = ISNULL(fShippingTax,0),
    @cOrderItemId = ISNULL(cOrderItemId,N''),
    @cCarrier = ISNULL(cCarrier,N''),
    @cTrackingNumber = ISNULL(cTrackingNumber,N''),
    @dEstimatedArrivalDate = dEstimatedArrivalDate,
    @cFulfillmentCenterId = ISNULL(cFulfillmentCenterId,N''),
    @cFullfillmentChannel = N'',
    @cMerchantOrderItemid = ISNULL(cMerchantOrderItemid,N''),
    @nErrorCode = ISNULL(nErrorCode,0),
    @cErrorMessage = ISNULL(cErrorMessage,N''),
    @dErrorErstellt = dErrorErstellt,
    @fGeschenkverpackungKosten = ISNULL(fGeschenkverpackungKosten,0),
    @cGeschenkverpackungTyp = ISNULL(cGeschenkverpackungTyp,N''),
    @cGrusstext = ISNULL(cGrusstext,N''),
    @nGeschenk = ISNULL(nGeschenk,0),
    @kFulfillmentAuftragPos = ISNULL(kFulfillmentAuftragPos,0),
    @cCustomUrl = ISNULL(cCustomUrl,N''),
    @cCustomJson = ISNULL(cCustomJson,N''),
    @cArchiveUrl = ISNULL(cArchiveUrl,N''),
    @cShipmentItemId = ISNULL(cShipmentItemId,N'')
FROM dbo.pf_amazon_bestellungpos
WHERE kAmazonBestellungPos = @kAmazonBestellungPos;

EXEC Amazon.spAmazonPosAendern
    @kAmazonBestellungPos=@kAmazonBestellungPos,
    @kAmazonBestellung=@kAmazonBestellung,
    @cArtNr=@cArtNr,
    @cName=@cName,
    @nQuantityPurchased=@nQuantityPurchased,
    @fItemPrice=@fItemPrice,
    @fItemTax=@fItemTax,
    @fShippingPrice=@fShippingPrice,
    @fShippingTax=@fShippingTax,
    @cOrderItemId=@cOrderItemId,
    @nVersandt=@nQuantityPurchased,
    @cCarrier=@cCarrier,
    @cTrackingNumber=@cTrackingNumber,
    @dEstimatedArrivalDate=@dEstimatedArrivalDate,
    @cFulfillmentCenterId=@cFulfillmentCenterId,
    @cFullfillmentChannel=@cFullfillmentChannel,
    @cMerchantOrderItemid=@cMerchantOrderItemid,
    @nErrorCode=@nErrorCode,
    @cErrorMessage=@cErrorMessage,
    @dErrorErstellt=@dErrorErstellt,
    @fGeschenkverpackungKosten=@fGeschenkverpackungKosten,
    @cGeschenkverpackungTyp=@cGeschenkverpackungTyp,
    @cGrusstext=@cGrusstext,
    @nGeschenk=@nGeschenk,
    @kFulfillmentAuftragPos=@kFulfillmentAuftragPos,
    @cCustomUrl=@cCustomUrl,
    @cCustomJson=@cCustomJson,
    @cArchiveUrl=@cArchiveUrl,
    @cShipmentItemId=@cShipmentItemId;
"@
            [void]$amazonShipCmd.Parameters.Add("@kAmazonBestellungPos",[Data.SqlDbType]::Int)
            $amazonShipCmd.Parameters["@kAmazonBestellungPos"].Value = $amazonBestellungPos
            [void]$amazonShipCmd.Parameters.Add("@kAmazonBestellung",[Data.SqlDbType]::Int)
            $amazonShipCmd.Parameters["@kAmazonBestellung"].Value = $amazonBestellung
            [void]$amazonShipCmd.Parameters.Add("@kLieferschein",[Data.SqlDbType]::Int)
            $amazonShipCmd.Parameters["@kLieferschein"].Value = $queueLieferschein
            [void]$amazonShipCmd.Parameters.Add("@Tracking",[Data.SqlDbType]::NVarChar,255)
            $amazonShipCmd.Parameters["@Tracking"].Value = $Tracking
            [void]$amazonShipCmd.Parameters.Add("@ShipDate",[Data.SqlDbType]::DateTime)
            $amazonShipCmd.Parameters["@ShipDate"].Value = $dbVersendet
            [void]$amazonShipCmd.ExecuteNonQuery()
            $amazonHandled = $true
        }
        else {
            # Andere Verkaufskanaele: vorhandene JTL-Queue/SCX-Logik beibehalten.
            $queueCmd = $cn.CreateCommand()
            $queueCmd.Transaction = $tx
            $queueCmd.CommandText = @"
INSERT INTO dbo.tQueue
    (kShop, kPlattform, cName, kWert, nAction, kOption1, kOption2, nInBearbeitung)
VALUES
    (@kShop, @kPlattform, N'tLieferschein', @kLieferschein, 1, 0, 0, 0);
"@
            [void]$queueCmd.Parameters.Add("@kShop",[Data.SqlDbType]::Int)
            if ($null -eq $queueShop) {
                $queueCmd.Parameters["@kShop"].Value = [DBNull]::Value
            } else {
                $queueCmd.Parameters["@kShop"].Value = $queueShop
            }
            [void]$queueCmd.Parameters.Add("@kPlattform",[Data.SqlDbType]::Int)
            $queueCmd.Parameters["@kPlattform"].Value = $queuePlattform
            [void]$queueCmd.Parameters.Add("@kLieferschein",[Data.SqlDbType]::Int)
            $queueCmd.Parameters["@kLieferschein"].Value = $queueLieferschein

            $queueAffected = $queueCmd.ExecuteNonQuery()
            if ($queueAffected -ne 1) {
                throw "Versandstatus-Queue hat $queueAffected Zeilen angelegt; erwartet 1."
            }

            $scxCmd = $cn.CreateCommand()
            $scxCmd.Transaction = $tx
            $scxCmd.CommandText = @"
MERGE SCX.tOrderShipping AS Target
USING (
    SELECT
        o.kOrder AS kOrder,
        l.kLieferschein,
        GETUTCDATE() AS dCreatedAtUtc
    FROM dbo.tVersand v
    JOIN dbo.tLieferschein l ON l.kLieferschein = v.kLieferschein
    JOIN Verkauf.tAuftrag a ON a.kAuftrag = l.kBestellung
    JOIN SCX.tOrder o ON o.kAuftrag = a.kAuftrag
    WHERE v.kVersand = @kVersand
) AS Shipping
ON Shipping.kLieferschein = Target.kLieferschein
WHEN MATCHED THEN
    UPDATE SET Target.dUploadedAtUtc = NULL, Target.nCount = 0
WHEN NOT MATCHED BY TARGET THEN
    INSERT (kOrder, kLieferschein, dCreatedAtUtc)
    VALUES (Shipping.kOrder, Shipping.kLieferschein, Shipping.dCreatedAtUtc);
"@
            [void]$scxCmd.Parameters.Add("@kVersand",[Data.SqlDbType]::Int)
            $scxCmd.Parameters["@kVersand"].Value = $kVersand
            $scxAffected = $scxCmd.ExecuteNonQuery()
        }

        $queueShopText = if ($null -eq $queueShop) { 'NULL' } else { [string]$queueShop }
        if ($amazonHandled) {
            Write-Log "Amazon-Versandstatus SQL vorgemerkt: Auftrag=$queueAuftrag Plattform=$amazonPlatformId Lieferschein=$queueLieferschein Tracking=$Tracking"
        } else {
            Write-Log "Versandstatus-Queue OK: Auftrag=$queueAuftrag Plattform=$queuePlattform Shop=$queueShopText Lieferschein=$queueLieferschein"
            if ($scxAffected -gt 0) {
                Write-Log "SCX-Versandstatus OK: Auftrag=$queueAuftrag Lieferschein=$queueLieferschein Treffer=$scxAffected"
            } else {
                Write-Log "SCX-Versandstatus: kein SCX.tOrder-Treffer fuer Auftrag=$queueAuftrag Plattform=$queuePlattform (kein Fehler)."
            }
        }
        } else {
            Write-Log 'Experimentelle SQL-Versandstatus-Queue deaktiviert. Tracking wurde in JTL eingetragen; Kanal-Rueckmeldung gesondert ausloesen.' 'WARN'
        }
        # kReturnVersandart bei OTTO bewusst nicht setzen.
        $tx.Commit()
    }
    catch {
        try { $tx.Rollback() } catch {}
        throw
    }
    finally {
        $cn.Close()
    }
}

function Read-SemicolonCsv {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = $null
    try {
        $utf8Strict = New-Object Text.UTF8Encoding($false, $true)
        $text = $utf8Strict.GetString($bytes)
    } catch {
        $text = [Text.Encoding]::Default.GetString($bytes)
    }

    # BOM und leere Zeilen entfernen. JTL kann je nach Vorlage Leerzeilen erzeugen.
    $text = $text.TrimStart([char]0xFEFF)
    $lines = @([Regex]::Split($text, "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 2) { throw 'CSV benötigt Kopfzeile und mindestens einen Datensatz.' }

    $headerParts = @($lines[0].Trim().Split(';') | ForEach-Object { $_.Trim() })
    # Ein versehentliches Semikolon am Ende der Kopfzeile erzeugt in PowerShell einen leeren Header.
    while ($headerParts.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$headerParts[$headerParts.Count-1])) {
        if ($headerParts.Count -eq 1) { $headerParts = @(); break }
        $headerParts = @($headerParts[0..($headerParts.Count-2)])
    }
    if ($headerParts.Count -eq 0) { throw 'CSV-Kopfzeile ist leer.' }
    if (@($headerParts | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
        throw 'CSV-Kopfzeile enthält eine leere Spaltenbezeichnung. Bitte überflüssige Semikolons in der JTL-Kopfzeile entfernen.'
    }

    $required = @('PaketRef','Lieferschein','Versandart','Vorname','Nachname','Firma','Adresszusatz','Strasse','Hausnummer','PLZ','Ort','LandISO','Email','Telefon','Mobil','Gewicht')
    $missing = @($required | Where-Object { $_ -notin $headerParts })
    if ($missing.Count -gt 0) { throw ('CSV-Kopfzeile unvollständig. Es fehlen: ' + ($missing -join ', ')) }

    $normalizedHeader = ($headerParts -join ';')
    $dataLines = @($lines | Select-Object -Skip 1)
    $csvText = $normalizedHeader + "`r`n" + ($dataLines -join "`r`n")
    $rows = @($csvText | ConvertFrom-Csv -Delimiter ';')
    return $rows
}

function Wait-FileStable {
    param([string]$Path)
    $last = -1L
    for ($i=0; $i -lt 10; $i++) {
        if (-not (Test-Path $Path)) { return $false }
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -gt 0 -and $len -eq $last) { return $true }
        $last = $len
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Clean-OptionalText {
    param([string]$Value, [int]$Max = 999)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v.Length -gt $Max) { $v = $v.Substring(0,$Max) }
    return $v
}

function Build-Consignee {
    param($Row)
    # DHL Paket API: Empfaenger-Namenszeilen konservativ auf 35 Zeichen begrenzen.
    # Dadurch vermeiden wir Soft-Warnings wie consignee.name1 'zu lang und wurde gekuerzt'.
    $first = Clean-OptionalText ([string]$Row.Vorname) 35
    $last  = Clean-OptionalText ([string]$Row.Nachname) 35
    $company = Clean-OptionalText ([string]$Row.Firma) 35
    $person = (($first, $last | Where-Object { $_ }) -join ' ').Trim()
    $person = Clean-OptionalText $person 35

    $name1 = if ($company) { $company } else { $person }
    if ([string]::IsNullOrWhiteSpace($name1)) { throw 'Empfängername/Firma fehlt.' }

    $consignee = [ordered]@{
        name1         = $name1
        addressStreet = (Clean-OptionalText ([string]$Row.Strasse) 50)
        postalCode    = (Clean-OptionalText ([string]$Row.PLZ) 10)
        city          = (Clean-OptionalText ([string]$Row.Ort) 40)
        country       = (Convert-CountryToAlpha3 ([string]$Row.LandISO))
    }
    if ($company -and $person) { $consignee.name2 = $person }
    $house = Clean-OptionalText ([string]$Row.Hausnummer) 10
    if ($house) { $consignee.addressHouse = $house }
    $add = Clean-OptionalText ([string]$Row.Adresszusatz) 60
    if ($add) { $consignee.additionalAddressInformation1 = $add }

    if ([bool]$script:Config.TransmitRecipientEmail) {
        $email = Clean-OptionalText ([string]$Row.Email) 80
        if ($email) { $consignee.email = $email }
    }
    # Für nationale DE-Sendungen übermitteln wir Telefonnummern standardmäßig nicht.
    if ([bool]$script:Config.TransmitRecipientPhone -and $consignee.country -ne 'DEU') {
        $phone = Clean-OptionalText ([string]$Row.Mobil) 20
        if (-not $phone) { $phone = Clean-OptionalText ([string]$Row.Telefon) 20 }
        if ($phone) { $consignee.phone = $phone }
    }

    if ([string]::IsNullOrWhiteSpace([string]$consignee.addressStreet)) { throw 'Straße fehlt.' }
    if ([string]::IsNullOrWhiteSpace([string]$consignee.postalCode)) { throw 'PLZ fehlt.' }
    if ([string]::IsNullOrWhiteSpace([string]$consignee.city)) { throw 'Ort fehlt.' }
    return $consignee
}

function Get-Shipper {
    if ($script:Config.Environment -eq 'Sandbox') {
        # Eine Absenderreferenz aus dem eigenen GKP existiert in der gemeinsamen DHL-Sandbox nicht.
        # Deshalb verwenden wir dort eine neutrale Testadresse. In Produktion wird wieder shipperRef verwendet.
        if ($script:Config.PSObject.Properties['SandboxShipper']) {
            $ss = $script:Config.SandboxShipper
            return [ordered]@{
                name1         = [string]$ss.name1
                addressStreet = [string]$ss.addressStreet
                addressHouse  = [string]$ss.addressHouse
                postalCode    = [string]$ss.postalCode
                city          = [string]$ss.city
                country       = [string]$ss.country
            }
        }
        return [ordered]@{
            name1='DHL Sandbox Test'; addressStreet='Straesschensweg'; addressHouse='10';
            postalCode='53113'; city='Bonn'; country='DEU'
        }
    }
    return [ordered]@{ shipperRef = [string]$script:Config.ShipperRef }
}

function Build-OrderBody {
    param($Row, [string]$Product, [string]$Billing, [double]$WeightKg)
    $shipper = Get-Shipper
    $shipment = [ordered]@{
        product       = $Product
        billingNumber = $Billing
        refNo         = ([string]$Row.Lieferschein)
        shipper       = $shipper
        consignee     = (Build-Consignee $Row)
        details       = [ordered]@{
            weight = [ordered]@{ uom='kg'; value=$WeightKg }
        }
    }

    # DHL Paket International (V53WPAK): Vorausverfügung.
    # RETURN = bei Unzustellbarkeit an den Absender zurückführen.
    # Für EU-Ziele werden bewusst KEINE Zolldaten erzeugt.
    if ($Product -eq 'V53WPAK') {
        $shipment.services = [ordered]@{
            endorsement = 'RETURN'
        }
    }

    # Warenpost International (V66WPI) wird hier mit PREMIUM gebucht.
    # Premium aktiviert die für das Zielland verfügbaren Premium-Leistungen, insbesondere Tracking.
    if ($Product -eq 'V66WPI') {
        $shipment.services = [ordered]@{
            premium = $true
        }
    }

    if (([string]$Row.Versandart).Trim() -eq 'DHL Otto') {
        $shipment.services = [ordered]@{
            dhlRetoure = [ordered]@{
                billingNumber = (Get-OttoReturnBillingNumber)
                refNo         = ([string]$Row.Lieferschein)
                returnAddress = (Get-OttoReturnAddress)
            }
        }
    }

    return [ordered]@{
        profile   = [string]$script:Config.Profile
        shipments = @($shipment)
    }
}

function Invoke-DhlOrder {
    param($Body, [bool]$Validate)
    $headers = Get-AuthHeaders
    $validateText = if ($Validate) { 'true' } else { 'false' }
    $mustEncodeText = if ([bool]$script:Config.MustEncode) { 'true' } else { 'false' }

    # Beim Dry-Run nur Parameter mitsenden, die für die Validierung nötig sind.
    # Label-/Dokumentparameter werden erst bei der echten Sandbox-Erstellung ergänzt.
    $url = "$(Get-BaseUrl)/orders?validate=$validateText&mustEncode=$mustEncodeText"
    if (-not $Validate) {
        # OTTO: Hinweg- und Retourenlabel NICHT kombinieren.
        # So enthaelt $item.label nur das normale Versandlabel; das OTTO-Retourenlabel
        # wird nicht Bestandteil der PDF-Datei im LabelPath und damit nicht gedruckt.
        $isOttoRequest = $false
        try {
            if ($Body.shipments -and $Body.shipments.Count -gt 0 -and
                $Body.shipments[0].services -and
                $Body.shipments[0].services.dhlRetoure) {
                $isOttoRequest = $true
            }
        } catch { $isOttoRequest = $false }

        $combineText = if ($isOttoRequest) { 'false' } else { 'true' }
        $url += '&includeDocs=include&docFormat=PDF&combine=' + $combineText
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Config.PrintFormat)) {
            $url += '&printFormat=' + [Uri]::EscapeDataString([string]$script:Config.PrintFormat)
        }
        if ($isOttoRequest) {
            Write-Log 'OTTO-Druck: combine=false - Retourenlabel wird nicht mit dem Versandlabel kombiniert/gedruckt.' 'INFO'
        }
    }

    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    try {
        return Invoke-RestMethod -Method Post -Uri $url -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
    } catch {
        $detail = Get-HttpErrorText $_

        # DHL liefert auch reine Soft-Warnings mit HTTP 400. Invoke-RestMethod wirft
        # dabei bereits eine Exception, bevor Assert-DhlResponseOK die Antwort sehen kann.
        # Deshalb versuchen wir hier, den JSON-Body zu extrahieren und reine Warnings
        # als normale DHL-Antwort an den Aufrufer weiterzugeben.
        $warningResponse = $null
        try {
            $jsonStart = $detail.IndexOf('{')
            if ($jsonStart -ge 0) {
                $problemJson = $detail.Substring($jsonStart)
                $candidate = $problemJson | ConvertFrom-Json -ErrorAction Stop
                $allMessages = @()
                if ($candidate.PSObject.Properties['items']) {
                    foreach ($ci in @($candidate.items)) {
                        if ($ci.PSObject.Properties['validationMessages'] -and $ci.validationMessages) {
                            $allMessages += @($ci.validationMessages)
                        }
                    }
                }
                if ($allMessages.Count -gt 0) {
                    $nonWarnings = @($allMessages | Where-Object { ([string]$_.validationState) -ne 'Warning' })
                    if ($nonWarnings.Count -eq 0) {
                        $warningResponse = $candidate
                    }
                }
            }
        } catch {
            $warningResponse = $null
        }

        if ($warningResponse) {
            Write-Log "DHL meldet HTTP 400, aber ausschliesslich Soft-Warnings. Verarbeitung wird fortgesetzt. $detail" 'WARN'
            return $warningResponse
        }

        $requestPath = Save-DebugText 'dhl_request' ("URL: $url`r`n`r`n$json")
        $errorPath = Save-DebugText 'dhl_error' $detail
        if ($requestPath) { Write-Log "DHL-Debug Request gespeichert: $requestPath" 'WARN' }
        if ($errorPath) { Write-Log "DHL-Debug Fehler gespeichert: $errorPath" 'WARN' }
        throw "DHL API Fehler: $detail"
    }
}

function Assert-DhlResponseOK {
    param($Response, [string]$Phase)
    if (-not $Response) { throw "DHL ${Phase}: leere Antwort." }
    $items = @()
    if ($Response.PSObject.Properties['items']) { $items = @($Response.items) }
    if ($items.Count -lt 1) {
        if ($Response.PSObject.Properties['status'] -and $Response.status) { throw "DHL ${Phase}: $($Response.status | ConvertTo-Json -Compress)" }
        throw "DHL ${Phase}: keine items in Antwort."
    }
    $item = $items[0]
    $status = $null
    if ($item.sstatus) {
        if ($item.sstatus.status) { $status = [int]$item.sstatus.status }
        elseif ($item.sstatus.statusCode) { $status = [int]$item.sstatus.statusCode }
    }
    if ($status -and $status -ge 400) {
        $messages = @()
        if ($item.validationMessages) { $messages = @($item.validationMessages) }
        $onlyWarnings = $false
        if ($messages.Count -gt 0) {
            $nonWarnings = @($messages | Where-Object { ([string]$_.validationState) -ne 'Warning' })
            $onlyWarnings = ($nonWarnings.Count -eq 0)
        }

        if ($onlyWarnings) {
            $msgs = ($messages | ConvertTo-Json -Compress)
            Write-Log "DHL ${Phase}: nur Soft-Warnings trotz Status $status. $msgs" 'WARN'
            return $item
        }

        $msgs = ''
        if ($messages.Count -gt 0) { $msgs = ($messages | ConvertTo-Json -Compress) }
        throw "DHL $Phase fehlgeschlagen (Status $status). $msgs"
    }
    return $item
}

function Save-Label {
    param($Item, [string]$PaketRef, [string]$Lieferschein)
    if (-not $Item.label) { throw 'DHL hat kein Label zurückgegeben.' }
    $safeRef = ($PaketRef -replace '[^A-Za-z0-9_-]','_')
    $safeLs  = ($Lieferschein -replace '[^A-Za-z0-9_-]','_')
    $labelPath = Join-Path $script:Config.LabelPath ("{0}_{1}.pdf" -f $safeLs,$safeRef)
    if ($Item.label.b64) {
        [IO.File]::WriteAllBytes($labelPath, [Convert]::FromBase64String([string]$Item.label.b64))
    } elseif ($Item.label.url) {
        Invoke-WebRequest -Uri ([string]$Item.label.url) -OutFile $labelPath
    } else {
        throw 'Label enthält weder b64 noch URL.'
    }
    if ([bool]$script:Config.AutoPrintPdf) {
        try { Start-Process -FilePath $labelPath -Verb Print | Out-Null } catch { Write-Log "Automatischer PDF-Druck fehlgeschlagen: $($_.Exception.Message)" 'WARN' }
    }
    return $labelPath
}

function Write-TrackingBackup {
    param([string]$PaketRef, [string]$Lieferschein, [string]$Tracking)
    $safeRef = ($PaketRef -replace '[^A-Za-z0-9_-]','_')
    $safeLs  = ($Lieferschein -replace '[^A-Za-z0-9_-]','_')
    $backupDir = Join-Path $script:Config.ImportPath 'backup'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $file = Join-Path $backupDir ("tracking_{0}_{1}_{2}.csv" -f $safeLs,$safeRef,(Get-Date -Format 'yyyyMMdd_HHmmssfff'))
    $content = "PaketRef;Tracking`r`n$PaketRef;$Tracking`r`n"
    [IO.File]::WriteAllText($file, $content, (New-Object Text.UTF8Encoding($true)))
    return $file
}

function Get-StateFile {
    param([string]$PaketRef)
    $safe = ($PaketRef -replace '[^A-Za-z0-9_-]','_')
    $envName = [string]$script:Config.Environment
    $envStatePath = Join-Path $script:Config.StatePath $envName
    if (-not (Test-Path $envStatePath)) { New-Item -ItemType Directory -Path $envStatePath -Force | Out-Null }
    return Join-Path $envStatePath ($safe + '.json')
}

function Process-Row {
    param($Row, [string]$SourceFile)

    $paketRef = ([string]$Row.PaketRef).Trim()
    $ls = ([string]$Row.Lieferschein).Trim()
    $versandart = ([string]$Row.Versandart).Trim()

    if ([string]::IsNullOrWhiteSpace($paketRef)) { throw 'PaketRef fehlt.' }
    if ([string]::IsNullOrWhiteSpace($ls)) { throw 'Lieferschein fehlt.' }
    if ([string]::IsNullOrWhiteSpace($versandart)) { throw 'Versandart fehlt.' }

    $weight = Convert-WeightKg ([string]$Row.Gewicht)
    $productInfo = Get-ProductInfo $versandart $weight ([string]$Row.LandISO)

    $isOtto = $false
    if ($productInfo.ContainsKey('IsOtto')) { $isOtto = [bool]$productInfo.IsOtto }

    $stateFile = Get-StateFile $paketRef

    # Wenn DHL bereits erfolgreich gebucht wurde, aber das JTL-Update fehlgeschlagen ist,
    # niemals erneut bei DHL buchen. Nur das JTL-Tracking wird nachgeholt.
    if ((-not $ValidateOnly) -and (Test-Path $stateFile)) {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $status = [string]$state.status

        if ($status -in @('DHL_CREATED_PENDING_JTL','OTTO_DHL_CREATED_PENDING_JTL')) {
            $pendingReturn = ''
            if ($state.PSObject.Properties['returnTracking']) {
                $pendingReturn = [string]$state.returnTracking
            }

            Write-Log "$paketRef / ${ls}: DHL wurde bereits gebucht. Hole nur das JTL-Tracking-Update nach ..."
            Write-JtlTracking $paketRef $ls $versandart ([string]$state.tracking) $pendingReturn

            $state.status = 'COMPLETED'
            $state.jtlDbUpdatedAt = (Get-Date).ToString('o')
            $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

            Write-Log "$paketRef / ${ls}: JTL-Update nachgeholt. Keine neue DHL-Buchung."
            return
        }

        Write-Log "$paketRef wurde bereits gebucht ($($state.tracking)). Überspringe Doppelbuchung."
        return
    }

    if ($ValidateOnly -and (Test-Path $stateFile)) {
        Write-Log "$paketRef ist bereits in der Buchungshistorie vorhanden; für ValidateOnly wird die Historie bewusst ignoriert."
    }

    # Vor jeder echten DHL-Buchung muss JTL erreichbar sein und PaketRef/Lieferschein/Versandart
    # müssen exakt passen. Dadurch erzeugen wir keine DHL-Sendung, wenn der spätere JTL-Rückweg
    # schon vorab offensichtlich nicht funktionieren kann.
    if (-not $ValidateOnly) {
        [void](Assert-JtlTrackingTarget $paketRef $ls $versandart $isOtto)
        Write-Log "$paketRef / ${ls}: JTL-Ziel geprüft und Trackingfeld leer. PaketRef -> tVersand eindeutig."
    }

    $billing = Get-BillingNumber $productInfo.Product
    $body = Build-OrderBody $Row $productInfo.Product $billing $weight

    # Transparente API-Parameter im Log ausgeben. So ist vor der Validierung/Buchung sichtbar,
    # welches DHL-Produkt, welche Abrechnungsnummer und welcher Premium-Status verwendet werden.
    $premiumLog = $false
    try {
        $servicesLog = $body.shipments[0].services
        if ($null -ne $servicesLog) {
            if ($servicesLog -is [System.Collections.IDictionary] -and $servicesLog.Contains('premium')) {
                $premiumLog = [bool]$servicesLog['premium']
            } elseif ($servicesLog.PSObject.Properties.Name -contains 'premium') {
                $premiumLog = [bool]$servicesLog.premium
            }
        }
    } catch { }
    Write-Log "$paketRef / ${ls}: API-Parameter: Produkt=$($productInfo.Product) | Billing=$billing | Premium=$premiumLog"

    Write-Log "$paketRef / ${ls}: validiere $($productInfo.Name), $weight kg, Environment=$($script:Config.Environment) ..."
    $validation = Invoke-DhlOrder $body $true
    [void](Assert-DhlResponseOK $validation 'Validierung')

    if ($ValidateOnly) {
        if ($isOtto) {
            Write-Log "$paketRef / ${ls}: OTTO PRODUCTION-VALIDIERUNG OK (70101 + dhlRetoure 70702). Keine Sendung erzeugt." 'INFO'
        } else {
            Write-Log "$paketRef / ${ls}: PRODUCTION-VALIDIERUNG OK. Keine Sendung erzeugt." 'INFO'
        }
        return
    }

    Write-Log "$paketRef / ${ls}: Validierung OK. Erzeuge $($script:Config.Environment)-Label ..."
    $created = Invoke-DhlOrder $body $false
    $item = Assert-DhlResponseOK $created 'Erstellung'

    $tracking = [string]$item.shipmentNo
    if ([string]::IsNullOrWhiteSpace($tracking)) {
        throw 'DHL hat keine Sendungsnummer zurückgegeben.'
    }

    $returnTracking = ''
    if ($isOtto) {
        $returnTracking = [string]$item.returnShipmentNo
        if ([string]::IsNullOrWhiteSpace($returnTracking)) {
            throw 'DHL hat für DHL Otto keine returnShipmentNo zurückgegeben.'
        }
    }

    $label = Save-Label $item $paketRef $ls
    $trackingBackup = Write-TrackingBackup $paketRef $ls $tracking

    # DHL-Nummern dauerhaft sichern, BEVOR JTL beschrieben wird.
    # Falls das DB-Update danach scheitert, wird beim nächsten Worker-Lauf
    # ausschließlich das JTL-Update wiederholt.
    $pendingState = [ordered]@{
        paketRef       = $paketRef
        lieferschein   = $ls
        versandart     = $versandart
        tracking       = $tracking
        returnTracking = $returnTracking
        product        = $productInfo.Product
        country        = $productInfo.Country
        environment    = [string]$script:Config.Environment
        labelPath      = $label
        trackingBackup = $trackingBackup
        sourceFile     = $SourceFile
        status         = 'DHL_CREATED_PENDING_JTL'
        createdAt      = (Get-Date).ToString('o')
    }
    $pendingState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    if ($isOtto) {
        Write-Log "$paketRef / ${ls}: DHL OK. Hinweg=$tracking, OTTO-Retoure=$returnTracking. Schreibe beide Nummern direkt nach JTL ..."
    } else {
        Write-Log "$paketRef / ${ls}: DHL OK. Tracking=$tracking. Schreibe Tracking direkt nach JTL ..."
    }

    Write-JtlTracking $paketRef $ls $versandart $tracking $returnTracking

    $pendingState.status = 'COMPLETED'
    $pendingState.jtlDbUpdatedAt = (Get-Date).ToString('o')
    $pendingState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

    if ($isOtto) {
        Write-Log "${paketRef}: OTTO KOMPLETT. Hinweg=$tracking, Retoure=$returnTracking, JTL automatisch aktualisiert."
    } else {
        Write-Log "${paketRef}: KOMPLETT. Tracking=$tracking direkt in JTL eingetragen. Kein Versanddatenimport nötig."
    }
}

function Process-File {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    if (-not (Wait-FileStable $Path)) { Write-Log "$name ist noch nicht stabil; später erneut." 'WARN'; return }
    Write-Log "Verarbeite $name"
    try {
        $rows = @(Read-SemicolonCsv $Path)
        if ($rows.Count -eq 0) { throw 'CSV enthält keine Datensätze.' }
        foreach ($row in $rows) { Process-Row $row $name }
        if ($ValidateOnly) {
            Write-Log "$name -> Nur validiert, Datei bleibt unverändert."
        } else {
            $dest = Join-Path $script:Config.ProcessedPath $name
            if (Test-Path $dest) { $dest = Join-Path $script:Config.ProcessedPath (([IO.Path]::GetFileNameWithoutExtension($name)) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmssfff') + '.csv') }
            Move-Item -LiteralPath $Path -Destination $dest
            Write-Log "$name -> Verarbeitet"
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Log "$name FEHLER: $msg" 'ERROR'
        $errTxt = Join-Path $script:Config.ErrorPath (([IO.Path]::GetFileNameWithoutExtension($name)) + '.error.txt')
        [IO.File]::WriteAllText($errTxt, $msg, [Text.Encoding]::UTF8)
        if ((-not $ValidateOnly) -and (Test-Path $Path)) {
            $dest = Join-Path $script:Config.ErrorPath $name
            if (Test-Path $dest) { $dest = Join-Path $script:Config.ErrorPath (([IO.Path]::GetFileNameWithoutExtension($name)) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmssfff') + '.csv') }
            Move-Item -LiteralPath $Path -Destination $dest
        }
    }
}


function Acquire-AutoProductionLock {
    if (-not $AutoProduction) { return }

        $lockDir = Join-Path $env:LOCALAPPDATA 'JTL-DHL-Worker'
    if (-not (Test-Path $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }

    $lockPath = Join-Path $lockDir 'production-worker.lock'
    try {
        $script:ProductionLockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $script:ProductionLockStream.SetLength(0)
        $bytes = [Text.Encoding]::UTF8.GetBytes(("PID={0}`r`nStarted={1}`r`n" -f $PID,(Get-Date).ToString('o')))
        $script:ProductionLockStream.Write($bytes,0,$bytes.Length)
        $script:ProductionLockStream.Flush()
    } catch {
        throw "Ein Production-Worker läuft bereits. Doppelstart wurde verhindert."
    }
}

$script:Config = Read-Config
Ensure-Directories
Assert-Config
Acquire-AutoProductionLock
Write-Log "JTL DHL Community Worker v1.14 gestartet. Environment=$($script:Config.Environment), ShipperRef=$($script:Config.ShipperRef), ValidateOnly=$ValidateOnly, AutoProduction=$AutoProduction"
Write-Log "Export: $($script:Config.ExportPath)"

if (-not [string]::IsNullOrWhiteSpace($SpecificFile)) {
    $resolved = $SpecificFile
    if (-not [IO.Path]::IsPathRooted($resolved)) { $resolved = Join-Path $script:Config.ExportPath $resolved }
    if (-not (Test-Path $resolved)) { throw "SpecificFile nicht gefunden: $resolved" }
    Process-File $resolved
    exit 0
}

while ($true) {
    $files = @(Get-ChildItem -LiteralPath $script:Config.ExportPath -Filter '*.csv' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($f in $files) { Process-File $f.FullName }
    if ($Once) { break }
    Start-Sleep -Seconds ([int]$script:Config.PollSeconds)
}
