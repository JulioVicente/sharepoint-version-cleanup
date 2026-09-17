BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
    . (Join-Path $PSScriptRoot '../scripts/Configuration.ps1')
    function Get-PnPTenantId { param($TenantUrl) }
    function Connect-PnPOnline { param($Url,$Tenant,$ClientId,$Thumbprint,[switch]$ReturnConnection) }
    function Get-PnPWeb { param($Connection) }
    $appId = '11111111-1111-1111-1111-111111111111'
    $thumb = '0123456789ABCDEF0123456789ABCDEF01234567'
}
Describe 'Descoberta automatica no instalador' {
    It 'descobre tenant sem perguntar dominio ou URL administrativa' {
        Mock Get-PnPTenantId { '22222222-2222-2222-2222-222222222222' }
        Mock Read-Host { throw 'Nao deve perguntar' }
        $context = Get-CleanupTenantContext 'https://contoso.sharepoint.com/sites/piloto'
        $context.Tenant | Should -Be '22222222-2222-2222-2222-222222222222'
        $context.AdminUrl | Should -Be 'https://contoso-admin.sharepoint.com'
        Should -Invoke Read-Host -Times 0
    }
    It 'solicita tenant somente quando descoberta falha' {
        Mock Get-PnPTenantId { throw 'Indisponivel' }
        Mock Read-Host { 'contoso.onmicrosoft.com' }
        (Get-CleanupTenantContext 'https://contoso.sharepoint.com').Tenant | Should -Be 'contoso.onmicrosoft.com'
        Should -Invoke Read-Host -Times 1
    }
    It 'localiza aplicativo unico e carrega chaves sem perguntar identificadores' {
        Mock Get-SetupGraphCollection { @{id='object-id';appId=$appId;displayName='SharePoint Version Cleanup'} }
        Mock Invoke-SetupGraph { @{ id='object-id';appId=$appId;keyCredentials=@();requiredResourceAccess=@() } }
        Mock Read-Host { throw 'Nao deve perguntar' }
        (Find-CleanupApplication).appId | Should -Be $appId
        Should -Invoke Invoke-SetupGraph -ParameterFilter { $Path -eq 'applications/object-id?$select=id,appId,displayName,keyCredentials,requiredResourceAccess' }
        Should -Invoke Read-Host -Times 0
    }
    It 'propaga erro de permissao na busca em vez de criar outro aplicativo' {
        Mock Get-SetupGraphCollection { throw '403 Forbidden' }
        Mock Invoke-SetupGraph { throw 'Nao deve criar' }
        { Find-CleanupApplication } | Should -Throw '*403*'
        Should -Invoke Invoke-SetupGraph -Times 0
    }
    It 'reutiliza aplicativo encontrado mesmo sem declarar que ele existe' {
        Mock Find-CleanupApplication { @{id='object-id';appId=$appId} }
        Mock Get-SetupGraphCollection { @{id='principal'} }
        Mock Resolve-CleanupCertificate { @{Thumbprint=$thumb} }
        Mock Set-CleanupApplicationPermissions {}
        Mock Grant-CleanupSites {}
        Mock Invoke-SetupGraph { throw 'Nao deve recriar' }
        Mock Read-Host { throw 'Nao deve perguntar identificadores' }
        $auth = Register-CleanupApplication -Tenant contoso.onmicrosoft.com -CertificateDirectory $TestDrive -Sites @('https://contoso.sharepoint.com') -EnableGraphMail
        $auth.ClientId | Should -Be $appId
        $auth.CertificateThumbprint | Should -Be $thumb
        Should -Invoke Read-Host -Times 0
        Should -Invoke Grant-CleanupSites -Times 1
    }
    It 'seleciona somente certificado associado e com chave privada valida' {
        $matching = @{Thumbprint=$thumb;HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddYears(1)}
        Mock Get-ChildItem { @(
            @{Thumbprint=('A'*40);HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddYears(2)},
            $matching
        ) }
        Mock Read-Host { throw 'Nao deve pedir senha nem thumbprint' }
        $app = @{keyCredentials=@(@{type='AsymmetricX509Cert';usage='Verify';customKeyIdentifier=[Convert]::ToBase64String([Convert]::FromHexString($thumb));startDateTime=(Get-Date).AddDays(-1);endDateTime=(Get-Date).AddYears(1)})}
        (Resolve-CleanupCertificate -Application $app -CertificateDirectory $TestDrive).Thumbprint | Should -Be $thumb
        Should -Invoke Read-Host -Times 0
    }
    It 'preserva chaves remotas quando Graph nao retorna conteudo necessario' {
        Mock Get-ChildItem { @() }
        Mock Read-Host { throw 'Nao deve gerar certificado' }
        $app = @{keyCredentials=@(@{type='AsymmetricX509Cert';usage='Verify';customKeyIdentifier=$null;key=$null})}
        { Resolve-CleanupCertificate -Application $app -CertificateDirectory $TestDrive } | Should -Throw '*Nao e seguro*'
        Should -Invoke Read-Host -Times 0
    }
    It 'nao concede novamente acesso de escrita ja existente' {
        Mock Invoke-SetupGraph { @{id='site-id'} } -ParameterFilter { -not $Method -or $Method -eq 'GET' }
        Mock Get-SetupGraphCollection { @{id='permission-id';roles=@('write');grantedToIdentitiesV2=@(@{application=@{id=$appId}})} }
        Mock Invoke-SetupGraph {} -ParameterFilter { $Method -and $Method -ne 'GET' }
        Grant-CleanupSites -ClientId $appId -Sites @('https://contoso.sharepoint.com')
        Should -Invoke Invoke-SetupGraph -Times 0 -ParameterFilter { $Method -and $Method -ne 'GET' }
    }
    It 'wizard identifica remetente e sugere pasta Windows sem pedir tenant ou identificadores' {
        Mock Get-CleanupTenantContext { @{Tenant='contoso.onmicrosoft.com';AdminUrl='https://contoso-admin.sharepoint.com'} }
        Mock Connect-CleanupSetup {}
        Mock Invoke-SetupGraph { @{id='22222222-2222-2222-2222-222222222222';mail='operador@contoso.com';userPrincipalName='operador@contoso.com'} }
        Mock Register-CleanupApplication { @{ClientId=$appId;CertificateThumbprint=$thumb} }
        Mock Connect-PnPOnline { 'connection' }
        Mock Get-PnPWeb {}
        Mock Read-Host {
            param($Prompt)
            if ($Prompt -like 'URLs dos sites*') { return 'https://contoso.sharepoint.com' }
            if ($Prompt -like 'Caminho completo*') { return '/teste03' }
            if ($Prompt -match 'Client ID|Thumbprint|Dominio|Servidor SMTP|Porta SMTP|Senha SMTP|Ja possui') { throw "Pergunta desnecessaria: $Prompt" }
            return ''
        }
        $cfg = New-Configuration -Destination 'C:\ProgramData\SharePointVersionCleanup'
        $cfg.Email.From | Should -Be 'operador@contoso.com'
        $cfg.Email.SenderUserId | Should -Be '22222222-2222-2222-2222-222222222222'
        $cfg.Email.Provider | Should -Be 'Graph'
        $cfg.Audit.CopyDirectory | Should -Be 'C:\ProgramData\SharePointVersionCleanup\audit-copy'
        Should -Invoke Connect-CleanupSetup -Times 1
    }
}

Describe 'Atualizacao segura do aplicativo' {
    BeforeAll {
        function New-SelfSignedCertificate { param($Subject,$CertStoreLocation,$KeyAlgorithm,$KeyLength,$HashAlgorithm,$KeySpec,$KeyExportPolicy,$NotBefore,$NotAfter) }
        function Export-PfxCertificate { param($Cert,$FilePath,$Password) }
        function Export-Certificate { param($Cert,$FilePath) }
    }
    It 'acrescenta certificado sem remover chave anterior' {
        Mock Get-ChildItem { @() }
        Mock Read-Host { ConvertTo-SecureString 'senha-de-teste' -AsPlainText -Force }
        Mock New-SelfSignedCertificate {
            $cert = [pscustomobject]@{Thumbprint=$thumb;NotBefore=(Get-Date).AddMinutes(-5);NotAfter=(Get-Date).AddYears(1);RawData=[byte[]]@(1,2,3)}
            $cert | Add-Member ScriptMethod GetCertHash { [byte[]]@(4,5,6) }
            $cert
        }
        Mock Export-PfxCertificate {}
        Mock Export-Certificate {}
        Mock Invoke-SetupGraph {}
        $oldKey = @{keyId='old-key';key='AQID';type='AsymmetricX509Cert';usage='Verify';customKeyIdentifier=$null}
        $app = @{id='object-id';appId=$appId;keyCredentials=@($oldKey)}
        $cert = Resolve-CleanupCertificate -Application $app -CertificateDirectory (Join-Path $TestDrive 'certificates')
        $cert.Thumbprint | Should -Be $thumb
        Should -Invoke Invoke-SetupGraph -Times 1 -ParameterFilter {
            $Method -eq 'PATCH' -and $Path -eq 'applications/object-id' -and
            $Body.keyCredentials.Count -eq 2 -and $Body.keyCredentials[0].keyId -eq 'old-key' -and
            $Body.keyCredentials[1].key -eq 'AQID'
        }
        Should -Invoke Export-PfxCertificate -Times 1
    }
    It 'preserva permissoes existentes ao acrescentar Sites.Selected e Mail.Send' {
        Mock Get-SetupGraphCollection {
            if ($Path -match '0ff1') { @{appRoles=@(@{id='sites-role';value='Sites.Selected';allowedMemberTypes=@('Application');isEnabled=$true})} }
            else { @{appRoles=@(@{id='mail-role';value='Mail.Send';allowedMemberTypes=@('Application');isEnabled=$true})} }
        }
        Mock Invoke-SetupGraph {}
        Mock Read-Host { '' }
        $app = @{id='object-id';appId=$appId;requiredResourceAccess=@(@{resourceAppId='00000003-0000-0000-c000-000000000000';resourceAccess=@(@{id='old-role';type='Role'})})}
        Set-CleanupApplicationPermissions -Application $app -EnableGraphMail
        Should -Invoke Invoke-SetupGraph -Times 1 -ParameterFilter {
            $roles = @($Body.requiredResourceAccess | ForEach-Object { $_.resourceAccess } | ForEach-Object { $_.id })
            $Method -eq 'PATCH' -and 'old-role' -in $roles -and 'mail-role' -in $roles -and 'sites-role' -in $roles
        }
    }
    It 'nao altera permissoes quando os papeis necessarios ja existem' {
        Mock Get-SetupGraphCollection { @{appRoles=@(@{id='sites-role';value='Sites.Selected';allowedMemberTypes=@('Application');isEnabled=$true})} }
        Mock Invoke-SetupGraph {}
        Mock Read-Host { throw 'Nao deve repetir consentimento' }
        $app = @{id='object-id';appId=$appId;requiredResourceAccess=@(@{resourceAppId='00000003-0000-0ff1-ce00-000000000000';resourceAccess=@(@{id='sites-role';type='Role'})})}
        Set-CleanupApplicationPermissions -Application $app
        Should -Invoke Invoke-SetupGraph -Times 0
        Should -Invoke Read-Host -Times 0
    }
    It 'seleciona entre nomes duplicados sem pedir GUID' {
        Mock Get-SetupGraphCollection { @(@{id='one';appId='first';displayName='SharePoint Version Cleanup'},@{id='two';appId='second';displayName='SharePoint Version Cleanup'}) }
        Mock Read-Host { '2' }
        Mock Invoke-SetupGraph { @{id='two';appId='second'} }
        (Find-CleanupApplication).appId | Should -Be 'second'
        Should -Invoke Invoke-SetupGraph -Times 1 -ParameterFilter { $Path -like 'applications/two?*' }
    }
}
