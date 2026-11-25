param(
    [string]$OutputFile = (Join-Path $PSScriptRoot 'production-credentials.json')
)

$apiKey = Read-Host 'DHL Production Client ID / API Key'
$apiSecret = Read-Host 'DHL Production Client Secret' -AsSecureString
$username = Read-Host 'DHL Production Benutzername'
$password = Read-Host 'DHL Production Passwort' -AsSecureString

function Protect-Secure([Security.SecureString]$Value) {
    if (-not $Value) { return '' }
    return ($Value | ConvertFrom-SecureString)
}

$obj = [ordered]@{
    ApiKey    = (($apiKey | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString)
    ApiSecret = (Protect-Secure $apiSecret)
    Username  = (($username | ConvertTo-SecureString -AsPlainText -Force) | ConvertFrom-SecureString)
    Password  = (Protect-Secure $password)
}

$obj | ConvertTo-Json | Set-Content -LiteralPath $OutputFile -Encoding UTF8
Write-Host "Production-Zugang verschluesselt gespeichert: $OutputFile"
Write-Host 'Wichtig: Die Datei ist an das Windows-Benutzerkonto gebunden, unter dem sie erstellt wurde.'
