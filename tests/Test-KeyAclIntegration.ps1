#requires -Version 7.4.6
[CmdletBinding()]
param([switch]$MachineKey)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Este teste de integracao exige Windows.' }
if ($MachineKey) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'O teste de ACL de maquina exige uma sessao elevada; nao pode ser considerado aprovado sem essa execucao.'
    }
}
. (Join-Path $PSScriptRoot '../scripts/TaskIdentity.ps1')
foreach ($kind in 'CAPI','CNG') {
    $name = 'SPVC-KeyAclTest-' + [guid]::NewGuid().ToString('N')
    $rsa = $null; $sourceKey = $null; $certificate = $null; $imported = $null; $privateKey = $null; $importedKey = $null; $pfx = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        if ($kind -eq 'CAPI') {
            $parameters = [Security.Cryptography.CspParameters]::new(24, 'Microsoft Enhanced RSA and AES Cryptographic Provider', $name)
            $parameters.KeyNumber = 2
            if ($MachineKey) { $parameters.Flags = [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore }
            $rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(2048, $parameters)
        } else {
            $parameters = [Security.Cryptography.CngKeyCreationParameters]::new()
            $parameters.ExportPolicy = [Security.Cryptography.CngExportPolicies]::AllowExport
            if ($MachineKey) { $parameters.KeyCreationOptions = [Security.Cryptography.CngKeyCreationOptions]::MachineKey }
            $sourceKey = [Security.Cryptography.CngKey]::Create([Security.Cryptography.CngAlgorithm]::Rsa, $name, $parameters)
            $rsa = [Security.Cryptography.RSACng]::new($sourceKey)
        }
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$name", $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $password = [guid]::NewGuid().ToString('N')
        $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $password)
        $flags = if ($MachineKey) { [Security.Cryptography.X509Certificates.X509KeyStorageFlags]'MachineKeySet,PersistKeySet' } else { [Security.Cryptography.X509Certificates.X509KeyStorageFlags]'UserKeySet,PersistKeySet' }
        $imported = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $password, $flags)
        $privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($imported)
        if ($privateKey -isnot [Security.Cryptography.RSACng]) { throw "O caso $kind deve reproduzir a representacao RSACng retornada pelo .NET." }
        $importedKey = $privateKey.Key
        $provider = Get-CleanupCertificateKeyProvider -Certificate $imported
        if (($kind -eq 'CAPI') -ne ($provider.ProviderType -ne 0)) { throw "Provedor $kind identificado incorretamente." }
        if ($kind -eq 'CAPI') {
            $info = Get-CleanupCapiKeyInfo -Provider $provider
            if ($info.MachineKeyStore -ne [bool]$MachineKey -or -not $info.UniqueKeyContainerName) { throw 'Armazenamento CAPI incorreto.' }
        }
        if ($MachineKey) {
            # Actual Windows providers and actual ACLs: no mocks and no existing certificate.
            Set-CleanupCertificatePrivateKeyAcl -Certificate $imported
            Set-CleanupCertificatePrivateKeyAcl -Certificate $imported
        }
        $openOptions = if ($MachineKey) { [Security.Cryptography.CngKeyOpenOptions]::MachineKey } else { [Security.Cryptography.CngKeyOpenOptions]::None }
        $reopened = $null
        if ($kind -eq 'CAPI') {
            $reopenParameters = [Security.Cryptography.CspParameters]::new([int]$provider.ProviderType, $provider.ProviderName, $provider.ContainerName)
            $reopenParameters.KeyNumber = [int]$provider.KeySpec
            $reopenParameters.Flags = [Security.Cryptography.CspProviderFlags]::UseExistingKey
            if ($MachineKey) { $reopenParameters.Flags = $reopenParameters.Flags -bor [Security.Cryptography.CspProviderFlags]::UseMachineKeyStore }
            $reopenedRsa = [Security.Cryptography.RSACryptoServiceProvider]::new($reopenParameters)
        } else {
            $reopened = [Security.Cryptography.CngKey]::Open($importedKey.KeyName, $importedKey.Provider, $openOptions)
            $reopenedRsa = [Security.Cryptography.RSACng]::new($reopened)
        }
        try {
            try {
                if ($MachineKey -and $kind -eq 'CNG') {
                    $descriptor = $reopened.GetProperty('Security Descr', [Security.Cryptography.CngPropertyOptions]4).GetValue()
                    $acl = [Security.AccessControl.RawSecurityDescriptor]::new($descriptor, 0)
                    $rules = @($acl.DiscretionaryAcl | Where-Object { $_.SecurityIdentifier.Value -eq 'S-1-5-19' })
                    if ($rules.Count -ne 1 -or $rules[0].AceQualifier -ne 'AccessAllowed' -or $rules[0].AccessMask -notin @(-2147483648,1179785)) {
                        throw 'ACL CNG nao persistiu apos reabrir a chave.'
                    }
                }
                $data = [Text.Encoding]::UTF8.GetBytes('SPVC disposable key ACL test')
                $signature = $reopenedRsa.SignData($data, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                if (-not $rsa.VerifyData($data, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Assinatura da chave reaberta invalida.' }
            } finally { $reopenedRsa.Dispose() }
        } finally { if ($reopened) { $reopened.Dispose() } }
        $scope = if ($MachineKey) { 'ACL de maquina aplicada, relida e reaplicada' } else { 'identificacao do provedor em chave de usuario' }
        Write-Host "PASS: $kind exposto como RSACng; $scope; chave reaberta e assinatura validada."
    } finally {
        # Delete only keys generated/imported in this iteration; never enumerate stores.
        if ($importedKey) {
            try { $importedKey.Delete() } catch { $cleanupErrors.Add($_.Exception.Message) }
            finally { $importedKey.Dispose() }
        }
        if ($privateKey) { $privateKey.Dispose() }
        if ($imported) { $imported.Dispose() }
        if ($certificate) { $certificate.Dispose() }
        if ($rsa -is [Security.Cryptography.RSACryptoServiceProvider]) { $rsa.PersistKeyInCsp = $false }
        if ($rsa) { $rsa.Dispose() }
        if ($sourceKey) {
            try {
                if ($sourceKey.KeyName -ne $name) { throw 'Identidade da chave temporaria divergente.' }
                $sourceKey.Delete()
            } catch { $cleanupErrors.Add($_.Exception.Message) }
            finally { $sourceKey.Dispose() }
        }
        if ($pfx) { [Array]::Clear($pfx, 0, $pfx.Length) }
        if ($cleanupErrors.Count) { throw "Falha ao limpar chaves descartaveis do teste ${name}: $($cleanupErrors -join '; ')" }
    }
}
