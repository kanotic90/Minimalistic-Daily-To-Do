# Code-signs dist\DailyTodoSetup.exe.
#
# Default: uses (or creates) a free self-signed "Daily To-Do" code-signing
# certificate in your personal certificate store. Pass -PfxPath / -PfxPassword
# to sign with a real purchased certificate instead.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sign-installer.ps1
#   powershell -ExecutionPolicy Bypass -File sign-installer.ps1 -PfxPath C:\my.pfx -PfxPassword 'secret'

param(
    [string]$PfxPath,
    [string]$PfxPassword,
    [string]$TimestampServer = "http://timestamp.digicert.com",
    [switch]$NoTrust   # skip trusting the self-signed cert locally
)

$ErrorActionPreference = "Stop"
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe    = Join-Path $Root "dist\DailyTodoSetup.exe"
$Subject = "CN=Daily To-Do"

if (-not (Test-Path $Exe)) { throw "Build the installer first: dist\DailyTodoSetup.exe not found." }

# --- pick the signing certificate ------------------------------------------
if ($PfxPath) {
    if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }
    $sec  = if ($PfxPassword) { ConvertTo-SecureString $PfxPassword -AsPlainText -Force } else { $null }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $cert.Import($PfxPath, $PfxPassword, "DefaultKeySet")
    Write-Host "Signing with purchased certificate: $($cert.Subject)"
} else {
    $cert = Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        Write-Host "Creating a self-signed code-signing certificate ($Subject)..."
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
                    -CertStoreLocation Cert:\CurrentUser\My `
                    -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 `
                    -FriendlyName "Daily To-Do Code Signing" `
                    -NotAfter (Get-Date).AddYears(5)
    } else {
        Write-Host "Reusing existing self-signed certificate ($Subject)."
    }
}

# --- trust the self-signed cert locally so the signature reads as Valid -----
# (No effect for other people's machines; purely for this user's experience.)
if (-not $PfxPath -and -not $NoTrust) {
    foreach ($storeName in @("Root", "TrustedPublisher")) {
        try {
            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "CurrentUser")
            $store.Open("ReadWrite")
            if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
                $store.Add($cert)
            }
            $store.Close()
        } catch {
            Write-Host "  (could not add to CurrentUser\${storeName}: $($_.Exception.Message))"
        }
    }
}

# --- sign (with timestamp so it stays valid after the cert expires) ---------
$signParams = @{ FilePath = $Exe; Certificate = $cert; HashAlgorithm = "SHA256" }
$res = Set-AuthenticodeSignature @signParams -TimestampServer $TimestampServer
if (-not $res.TimeStamperCertificate) {
    Write-Host "Timestamp not applied (server unreachable?); signature is still valid but will expire with the cert."
}

$sig = Get-AuthenticodeSignature $Exe
Write-Host ""
Write-Host "Signature status : $($sig.Status)"
Write-Host "Signer           : $($sig.SignerCertificate.Subject)"
if ($sig.TimeStamperCertificate) { Write-Host "Timestamped      : yes" } else { Write-Host "Timestamped      : no" }

# --- export public cert so recipients can trust it (optional for them) ------
if (-not $PfxPath) {
    $cerOut = Join-Path $Root "dist\DailyTodo-PublicCert.cer"
    Export-Certificate -Cert $cert -FilePath $cerOut -Type CERT | Out-Null
    Write-Host ""
    Write-Host "Public certificate exported to:"
    Write-Host "  $cerOut"
    Write-Host "A recipient who wants a fully-trusted signature can right-click it >"
    Write-Host "Install Certificate > Local Machine > Trusted Root Certification Authorities."
}
