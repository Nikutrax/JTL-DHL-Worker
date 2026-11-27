param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once,
    [switch]$ValidateOnly,
    [switch]$ApproveProductionShipment,
    [switch]$AutoProduction,
    [string]$SpecificFile = '',
    [switch]$CheckDuplicateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

    if ($script:Config.Environment -eq 'Sandbox' -and -not $ValidateOnly) { throw 'Sandbox nur im Validierungsmodus; kein Import und keine Buchung.' }

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
        # Eine Absenderreferenz aus dem echten GKP existiert in der gemeinsamen DHL-Sandbox nicht.
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

    # Warenpost International (V66WPI) wird in dieser Version als PREMIUM gebucht.
    # Premium aktiviert die für das Zielland verfügbaren Premium-Leistungen, insbesondere Tracking.
    if ($Product -eq 'V66WPI') {
        $shipment.services = [ordered]@{
            premium = $true
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
    $tempLabel = $labelPath + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    if ($Item.label.b64) {
        [IO.File]::WriteAllBytes($tempLabel, [Convert]::FromBase64String([string]$Item.label.b64))
    } elseif ($Item.label.url) {
        Invoke-WebRequest -Uri ([string]$Item.label.url) -OutFile $tempLabel
    } else {
        throw 'Label enthält weder b64 noch URL.'
    }
    if ((Get-Item -LiteralPath $tempLabel).Length -lt 5) { throw "Leeres Label; Reservierung bleibt erhalten." }
    [IO.File]::Move($tempLabel,$labelPath)
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

# CSV pilot: a reservation exists before the DHL creation request. Never retry a
# creation automatically after an uncertain result, even after a process crash.
function Write-CsvPilotState {
    param([string]$Path, $State, [switch]$Create)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $backup = $Path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
    $committed = $false
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 8))
        $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ($Create) { [IO.File]::Move($temp,$Path) }
        else { [IO.File]::Replace($temp,$Path,$backup) }
        $committed = $true
    } catch {
        # Preserve evidence of a successful DHL response if the NAS update fails.
        Write-Log "Statusspeicherung fehlgeschlagen. Keine Neubuchung. Status=$Path; Wiederherstellungsdatei=$temp; Backup=$backup" 'ERROR'
        throw
    } finally {
        if ($committed -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Test-CsvPilotStateStorage {
    param([string]$StateFile)
    $probe = Join-Path ([IO.Path]::GetDirectoryName($StateFile)) ('_storage_probe_' + [guid]::NewGuid().ToString('N'))
    try {
        Write-CsvPilotState $probe ([ordered]@{status='PROBE_CREATED'}) -Create
        Write-CsvPilotState $probe ([ordered]@{status='PROBE_REPLACED'})
        $check = Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
        if ($check.status -ne 'PROBE_REPLACED') { throw 'NAS Statusprobe fehlgeschlagen.' }
        Write-Log 'NAS Statusspeicherung: Create/Replace/Read OK.'
    } finally {
        Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($probe)) -Filter (([IO.Path]::GetFileName($probe)) + '*') | Remove-Item -Force
    }
}

function Publish-JtlTrackingCsv {
    param([string]$PaketRef,[string]$Tracking)
    if ($script:Config.Environment -ne 'Production') { throw 'Sandbox-Tracking darf nicht in den JTL-Import gelangen.' }
    if ($PaketRef -cnotmatch '^P[1-9][0-9]*$' -or $Tracking -notmatch '^[A-Za-z0-9-]+$') { throw 'Ungueltige Paket-ID oder Trackingnummer.' }
    $file = Join-Path $script:Config.ImportPath ("tracking_CSV_{0}.csv" -f $PaketRef)
    $temp = Join-Path $script:Config.ImportPath ('.tracking_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp,"PaketRef;Tracking`r`n$PaketRef;$Tracking`r`n",[Text.Encoding]::ASCII)
        [IO.File]::Move($temp,$file)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $file
}

# A local file guard is not proof that JTL or another shipping system has never booked a parcel.
function Assert-NoBookingEvidence {
    param([string]$PaketRef,[string]$Lieferschein,[string]$StateFile)
    if ($PaketRef -cnotmatch '^P[1-9][0-9]*$') { throw 'Ungueltige PaketRef.' }
    $stateDir = [IO.Path]::GetDirectoryName($StateFile)
    if ((Test-Path -LiteralPath $StateFile) -or @(Get-ChildItem -LiteralPath $stateDir -Filter ($PaketRef + '.json.*') -File -ErrorAction Stop).Count -gt 0) {
        throw "${PaketRef}: vorhandener Buchungsstatus oder Recovery-Datei. Keine neue Buchung."
    }
    if (@(Get-ChildItem -LiteralPath $script:Config.LabelPath -Filter "*_${PaketRef}.pdf" -File -ErrorAction Stop).Count -gt 0) { throw 'Vorhandenes Label. Keine neue Buchung.' }
    $existingCsv = Join-Path $script:Config.ImportPath ("tracking_CSV_{0}.csv" -f $PaketRef)
    if (Test-Path -LiteralPath $existingCsv) { throw 'Vorhandene Importdatei. Keine neue Buchung.' }
    $backupDir = Join-Path $script:Config.ImportPath 'backup'
    if ((Test-Path -LiteralPath $backupDir) -and @(Get-ChildItem -LiteralPath $backupDir -Filter "tracking_*_${PaketRef}_*.csv" -File -ErrorAction Stop).Count -gt 0) { throw 'Vorhandene Tracking-Sicherung. Keine neue Buchung.' }
}

# Monitor only files still waiting; disappearance is NOT a JTL acknowledgement.
$script:WarnedImports = @{}
function Watch-JtlImportQueue {
    $present = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $script:Config.ImportPath -Filter 'tracking_CSV_P*.csv' -File -ErrorAction Stop)) {
        $present[$f.Name] = $true
        if (((Get-Date) - $f.LastWriteTime).TotalMinutes -ge 5 -and -not $script:WarnedImports.ContainsKey($f.Name)) {
            Write-Log "JTL-Import wartet seit mindestens 5 Minuten: $($f.Name). JTL pruefen; keine Neubuchung." 'WARN'
            $script:WarnedImports[$f.Name] = $true
        }
    }
    foreach ($name in @($script:WarnedImports.Keys)) {
        if (-not $present.ContainsKey($name)) {
            Write-Log "Importdatei nicht mehr vorhanden: $name. JTL-Uebernahme nicht technisch bestaetigt."
            $script:WarnedImports.Remove($name)
        }
    }
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

    if ($paketRef -cnotmatch '^P[1-9][0-9]*$') { throw 'PaketRef muss P gefolgt von der internen Paketnummer sein.' }
    if ($isOtto) { throw 'DHL Otto wird im SQL-freien Pilotbetrieb nicht unterstuetzt. Keine DHL-Buchung.' }
    if ($AutoProduction -and $versandart -cne 'Versicherter Versand DHL') {
        throw 'CSV-Automatik: nur getesteter DHL Paket DE Versand freigegeben. Andere Versandarten manuell pruefen; keine Buchung.'
    }
    if (-not $ValidateOnly) {
        Assert-NoBookingEvidence $paketRef $ls $stateFile
        $probe = Join-Path $script:Config.ImportPath ('.probe_' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [IO.File]::WriteAllText($probe,'probe') } finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
        Write-Log "$paketRef / ${ls}: CSV-Betrieb; keine direkte JTL-Abfrage. Nur offene, ungebuchte Pakete exportieren."
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
    Write-Log "$paketRef / ${ls}: API-Parameter: Produkt=$($productInfo.Product) | Premium=$premiumLog"

    Write-Log "$paketRef / ${ls}: validiere $($productInfo.Name), $weight kg, Environment=$($script:Config.Environment) ..."
    $validation = Invoke-DhlOrder $body $true
    [void](Assert-DhlResponseOK $validation 'Validierung')

    if ($ValidateOnly) {
        Test-CsvPilotStateStorage $stateFile
        Write-Log "$paketRef / ${ls}: VALIDIERUNG OK. Keine Sendung erzeugt." 'INFO'
        return
    }

    $pendingState = [ordered]@{
        paketRef = $paketRef
        lieferschein = $ls
        versandart = $versandart
        tracking = ''
        returnTracking = ''
        product = $productInfo.Product
        country = $productInfo.Country
        environment = [string]$script:Config.Environment
        labelPath = ''
        trackingBackup = ''
        importFile = ''
        sourceFile = $SourceFile
        status = 'DHL_BOOKING_RESERVED'
        createdAt = (Get-Date).ToString('o')
    }
    Test-CsvPilotStateStorage $stateFile
    Write-CsvPilotState $stateFile $pendingState -Create
    Write-Log "$paketRef / ${ls}: Buchung reserviert. Erzeuge DHL-Label einmalig."
    $created = Invoke-DhlOrder $body $false
    $item = Assert-DhlResponseOK $created 'Erstellung'
    $tracking = [string]$item.shipmentNo
    if ([string]::IsNullOrWhiteSpace($tracking)) { throw 'DHL hat keine Sendungsnummer zurueckgegeben; Reservierung bleibt bestehen.' }
    $pendingState.tracking = $tracking
    $pendingState.status = 'DHL_CREATED_PENDING_CSV'
    Write-CsvPilotState $stateFile $pendingState

    $pendingState.labelPath = Save-Label $item $paketRef $ls
    $pendingState.trackingBackup = Write-TrackingBackup $paketRef $ls $tracking
    $pendingState.status = 'CSV_PUBLISH_PENDING'
    Write-CsvPilotState $stateFile $pendingState
    $pendingState.importFile = Publish-JtlTrackingCsv $paketRef $tracking
    $pendingState.status = 'CSV_PUBLISHED_UNCONFIRMED'
    Write-CsvPilotState $stateFile $pendingState
    Write-Log "${paketRef}: CSV bereitgestellt. Tracking=$tracking. JTL-Import und Versanddatum manuell kontrollieren."
}

function Process-File {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    if (-not (Wait-FileStable $Path)) { Write-Log "$name ist noch nicht stabil; später erneut." 'WARN'; return }
    Write-Log "Verarbeite $name"
    try {
        $rows = @(Read-SemicolonCsv $Path)
        if ($rows.Count -ne 1) { throw 'CSV-Betrieb erlaubt genau ein Paket pro Exportdatei; Mehrpaketsendungen manuell pruefen.' }
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
        throw
    }
}


function Acquire-AutoProductionLock {
    # Also lock the manual pilot against a running automatic worker.

    $lockDir = Join-Path $env:LOCALAPPDATA 'NikuTRAX-DHL-Worker'
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

# Separate opt-in: the existing AutoProductionEnabled alone is insufficient.
$script:Config = Read-Config
if ($CheckDuplicateOnly) {
    if ($AutoProduction -or $ApproveProductionShipment -or $ValidateOnly -or $Once -or $SpecificFile -cnotmatch '^P[1-9][0-9]*$') {
        throw 'Nur -CheckDuplicateOnly -SpecificFile P1234 (PaketRef), ohne weitere Modi.'
    }
    # No API call, no import, no booking, no export processing.
    $ref = $SpecificFile
    $stateFile = Join-Path (Join-Path $script:Config.StatePath $script:Config.Environment) ($ref + '.json')
    try { Assert-NoBookingEvidence $ref '' $stateFile; Write-Host 'KEIN LOKALER BUCHUNGSNACHWEIS. Keine Buchung ausgefuehrt.' }
    catch { Write-Host ('BUCHUNG GESPERRT: ' + $_.Exception.Message); if (-not (Test-Path -LiteralPath $stateFile)) { throw } }
    exit 0
}
if ($AutoProduction) {
    if ($SpecificFile -or $ApproveProductionShipment -or $ValidateOnly) { throw 'Automatikmodus darf nicht mit Einzeldatei, Freigabe oder Validierung kombiniert werden.' }
    if ($script:Config.Environment -ne 'Production') { throw 'CSV-Automatik nur fuer Production.' }
    if (-not $script:Config.PSObject.Properties['CsvAutomationEnabled'] -or ($script:Config.CsvAutomationEnabled -isnot [bool] -or -not $script:Config.CsvAutomationEnabled)) {
        throw 'CSV-Automatik gesperrt: CsvAutomationEnabled muss true sein.'
    }
    if (-not $script:Config.PSObject.Properties['CsvAutomationNotBefore']) { throw 'CsvAutomationNotBefore fehlt. Altdateien vor Freigabe pruefen.' }
    $script:Cutoff = [DateTimeOffset]::ParseExact([string]$script:Config.CsvAutomationNotBefore,'o',[Globalization.CultureInfo]::InvariantCulture)
    if ($script:Cutoff -gt [DateTimeOffset]::Now) { throw 'CsvAutomationNotBefore liegt in der Zukunft.' }
} elseif ([string]::IsNullOrWhiteSpace($SpecificFile)) {
    throw 'Einzeldatei mit -ValidateOnly oder -ApproveProductionShipment angeben.'
}
Ensure-Directories
Assert-Config
Acquire-AutoProductionLock
$script:NasLock = $null
try {
    # Cross-user / cross-host lock for this version; old worker must remain stopped.
    $nasLockPath = Join-Path $script:Config.StatePath 'csv-production-worker.lock'
    $script:NasLock = [IO.File]::Open($nasLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Write-Log "NikuTRAX DHL Worker v1.15-beta.1 CSV-Automatik gestartet. Environment=$($script:Config.Environment), ValidateOnly=$ValidateOnly, AutoProduction=$AutoProduction"
    Write-Log "Export: $($script:Config.ExportPath)"
    if (-not $AutoProduction) {
        $resolved = $SpecificFile
        if (-not [IO.Path]::IsPathRooted($resolved)) { $resolved = Join-Path $script:Config.ExportPath $resolved }
        if (-not (Test-Path -LiteralPath $resolved)) { throw "SpecificFile nicht gefunden: $resolved" }
        $full = [IO.Path]::GetFullPath($resolved)
        $parent = [IO.Path]::GetFullPath($script:Config.ExportPath).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine $parent -or [IO.Path]::GetExtension($full) -ine '.csv') { throw 'Nur CSV-Dateien direkt im Exportordner.' }
        Process-File $resolved
    } else {
        $poll = [Math]::Max(3,[int]$script:Config.PollSeconds)
        $oldReported = @{}
        do {
            Watch-JtlImportQueue
            foreach ($file in @(Get-ChildItem -LiteralPath $script:Config.ExportPath -Filter '*.csv' -File -ErrorAction Stop | Sort-Object LastWriteTime,Name)) {
                if ([DateTimeOffset]$file.LastWriteTime -lt $script:Cutoff) {
                    if (-not $oldReported.ContainsKey($file.Name)) { Write-Log "Altdatei gesperrt, manuell pruefen: $($file.Name)" 'WARN'; $oldReported[$file.Name] = $true }
                    continue
                }
                try { Process-File $file.FullName }
                catch {
                    # Process-File quarantines failed files. If that failed, stop rather than retry.
                    if (Test-Path -LiteralPath $file.FullName) { throw "Fehlerdatei konnte nicht archiviert werden. Automatik gestoppt: $($file.Name)" }
                    Write-Log "Auftrag in Fehlerordner; keine automatische Neubuchung: $($file.Name)" 'WARN'
                }
            }
            if (-not $Once) { Start-Sleep -Seconds $poll }
        } while (-not $Once)
    }
} finally {
    if ($null -ne $script:NasLock) { $script:NasLock.Dispose() }
    $script:ProductionLockStream.Dispose()
}
