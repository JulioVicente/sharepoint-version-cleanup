BeforeAll {
    $sourceRoot = Join-Path $PSScriptRoot '../scripts'
    function Connect-PnPOnline { param($Url,$Tenant,$ClientId,$Thumbprint,[switch]$ReturnConnection) }
    function Get-PnPList { param($Connection,$Includes,$Identity,[switch]$ThrowExceptionIfListNotFound) }
    function Get-PnPFolder { param($Url,$Connection) }
}
Describe 'Worker de validacao LOCAL SERVICE' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        foreach ($file in 'Test-ServiceContext.ps1','Configuration.ps1','Diagnostics.ps1','Progress.ps1','Formatting.ps1') {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination $fixture
        }
        $worker = Join-Path $fixture 'Test-ServiceContext.ps1'
        # Only the SID is injected for unit tests. The native Windows integration
        # executes the unmodified worker under the actual LOCAL SERVICE account.
        $source = [IO.File]::ReadAllText($worker).Replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value', "'S-1-5-19'")
        [IO.File]::WriteAllText($worker,$source)
        $cfg = Get-Content (Join-Path $PSScriptRoot '../config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Paths.State = $fixture
        $cfg.Paths.Logs = $fixture
        $configPath = Join-Path $fixture 'config.json'
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath
        $resultPath = Join-Path $fixture 'result.json'
        $modulePath = Join-Path $env:ProgramFiles 'PowerShell/Modules/PnP.PowerShell/3.4.1/PnP.PowerShell.psd1'
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=SPVC-unit', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $unitCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1),[DateTimeOffset]::UtcNow.AddDays(1))
        $context = [pscustomobject]@{RequestTimeout=0;Disposed=$false}
        $context | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        Mock Get-Item { $unitCertificate } -ParameterFilter { $LiteralPath -like 'Cert:*' }
        Mock Import-Module { [pscustomobject]@{Name='PnP.PowerShell';Version=[version]'3.4.1'} }
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Connect-PnPOnline { [pscustomobject]@{Context=$context} }
        Mock Get-PnPList { [pscustomobject]@{BaseTemplate=101;Hidden=$false;IsCatalog=$false;RootFolder=[pscustomobject]@{ServerRelativeUrl='/sites/piloto/Documentos Compartilhados'}} }
        Mock Get-PnPFolder { @{} }
    }
    AfterEach { $unitCertificate.Dispose(); $rsa.Dispose() }
    It 'valida certificado modulo bibliotecas e pasta antes de publicar sucesso Full' {
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeTrue
        $result.Scope | Should -Be Full
        $result.Stage | Should -Be completed
        $result.ModuleVersion | Should -Be '3.4.1'
        $context.RequestTimeout | Should -Be 60000
        $context.Disposed | Should -BeTrue
        Should -Invoke Get-PnPFolder -Times 1
        Should -Invoke Import-Module -Times 1 -ParameterFilter { $Name -eq $modulePath }
    }
    It 'valida todos os sites em vez de aceitar o primeiro' {
        $cfg.Sites += 'https://contoso.sharepoint.com/sites/segundo'
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        (Get-Content $resultPath -Raw | ConvertFrom-Json).Success | Should -BeTrue
        Should -Invoke Connect-PnPOnline -Times 2
        Should -Invoke Get-PnPList -Times 2
    }
    It 'preserva erro original se o formatador de diagnostico falhar' {
        "function Get-CleanupFailureHint { throw 'helper quebrado' }" | Add-Content (Join-Path $fixture 'Diagnostics.ps1')
        Mock Connect-PnPOnline { throw 'original 403' }
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeFalse
        $result.Error | Should -BeLike '*original 403*'
        $result.Error | Should -Not -BeLike '*helper quebrado*'
    }
    It 'identifica site e etapa da falha de conexao' {
        Mock Connect-PnPOnline { throw 'proxy 407' }
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeFalse
        $result.Stage | Should -Be connect
        $result.Error | Should -BeLike '*contoso.sharepoint.com*proxy 407*'
        Should -Invoke Get-PnPList -Times 0
    }
    It 'publica falha mesmo quando a dependencia de configuracao esta ausente' {
        Remove-Item (Join-Path $fixture 'Configuration.ps1')
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeFalse
        $result.Stage | Should -Be configuration
        $result.Error | Should -BeLike '*Configuration.ps1*'
    }
    It 'registra JSON invalido como falha de configuracao antes de acessar o certificado' {
        '{invalid' | Set-Content $configPath
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeFalse
        $result.Stage | Should -Be configuration
        Should -Invoke Connect-PnPOnline -Times 0
    }
    It 'recusa modulo de perfil do usuario' {
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath (Join-Path $fixture 'PnP.PowerShell.psd1')
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeFalse
        $result.Error | Should -BeLike '*Program Files*'
        Should -Invoke Import-Module -Times 0
    }
    It 'identifica teste local como parcial sem acessar rede' {
        & $worker -ConfigPath $configPath -ResultPath $resultPath -ModulePath $modulePath -LocalChecksOnly
        $result = Get-Content $resultPath -Raw | ConvertFrom-Json
        $result.Success | Should -BeTrue
        $result.Scope | Should -Be Local
        Should -Invoke Connect-PnPOnline -Times 0
    }
}
