#requires -Version 7.4.6
param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Configuration.ps1')
$result = @{ Success = $false; Error = ''; Identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
try {
    if ($result.Identity -ne 'S-1-5-19') { throw 'O teste deve executar como LOCAL SERVICE.' }
    $configuration = Read-CleanupConfiguration $ConfigPath
    Import-Module PnP.PowerShell -MinimumVersion 3.0.0 -MaximumVersion 3.9999.9999 -ErrorAction Stop
    $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($configuration.Authentication.CertificateThumbprint)"
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try { $null = $rsa.SignData([byte[]]@(1,2,3),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1) }
    finally { if ($rsa) { $rsa.Dispose() } }
    $paths = @($configuration.Paths.Logs,$configuration.Paths.State)
    if ($configuration.Audit.CopyDirectory) { $paths += $configuration.Audit.CopyDirectory }
    foreach ($path in $paths) {
        $probe = Join-Path $path ('service-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { [IO.File]::WriteAllText($probe,'probe') }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe } }
    }
    foreach ($site in $configuration.Sites) {
        $connection = Connect-PnPOnline -Url $site -Tenant $configuration.Tenant -ClientId $configuration.Authentication.ClientId -Thumbprint $configuration.Authentication.CertificateThumbprint -ReturnConnection -ErrorAction Stop
        $null = Get-CleanupLibraries -SiteUrl $site -FolderServerRelativeUrl $configuration.FolderScopes[$site] -Connection $connection
        if ($configuration.FolderScopes[$site]) {
            $null = Get-PnPFolder -Url $configuration.FolderScopes[$site] -Connection $connection -ErrorAction Stop
        }
    }
    $result.Success = $true
} catch { $result.Error = "$(Get-CleanupFailureHint $_) Erro original: $($_.Exception.Message)" }
$result | ConvertTo-Json | Set-Content -LiteralPath "$ResultPath.tmp" -Encoding utf8
[IO.File]::Move("$ResultPath.tmp",$ResultPath,$true)
if (-not $result.Success) { exit 1 }
