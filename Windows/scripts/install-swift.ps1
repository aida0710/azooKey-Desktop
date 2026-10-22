# Installs the Swift toolchain used for the Windows build (per user, silent).
# Matches the 6.2 line of the Linux test image (swift:6.2-noble).
param([string]$Version = '6.2.4')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$name = "swift-$Version-RELEASE-windows10.exe"
$installer = Join-Path $env:TEMP $name
Invoke-WebRequest -Uri "https://download.swift.org/swift-$Version-release/windows10/swift-$Version-RELEASE/$name" -OutFile $installer
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Apple Inc\.') {
    throw "Unexpected signature on $name : $($signature.Status) $($signature.SignerCertificate.Subject)"
}
$process = Start-Process -FilePath $installer -ArgumentList @('/quiet', '/norestart') -Wait -PassThru
if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) { throw "Swift installer failed ($($process.ExitCode))" }
