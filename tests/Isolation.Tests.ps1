BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
}

Describe 'Isolamento real de processos do instalador' {
    It 'nao herda assemblies e preserva parametros e relatorio' {
        Add-Type 'namespace SpvcIsolationTest { public class ParentOnly {} }'
        $report = Invoke-CleanupIsolated -ArgumentList @(@{Scope='/docs';Apply=$false}) -Action {
            param($Options)
            [pscustomobject]@{ Process=$PID; ParentTypeAvailable=[bool]('SpvcIsolationTest.ParentOnly' -as [type]); Scope=$Options.Scope; Apply=$Options.Apply; Warnings=@('aviso') }
        }
        $report.Process | Should -Not -Be $PID
        $report.ParentTypeAvailable | Should -BeFalse
        $report.Scope | Should -Be '/docs'
        $report.Apply | Should -BeFalse
        $report.Warnings | Should -Be @('aviso')
    }
    It 'timeout encapsulado recuperado no filho nao vira falha de Receive-Job' {
        $retryPath = Join-Path $PSScriptRoot '../scripts/Resilience.ps1'
        $report = Invoke-CleanupIsolated -ArgumentList @($retryPath) -Action {
            param($RetryScript)
            . $RetryScript
            function Start-Sleep {}
            $counter = @{Attempts=0}
            $result = Invoke-WithRetry -Settings @{MaxRetries=5;BaseDelaySeconds=2;MaxDelaySeconds=60} -Operation {
                $counter.Attempts++
                if ($counter.Attempts -eq 1) { Write-Error 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.' -ErrorAction Stop }
                'recuperado'
            }
            [pscustomobject]@{Success=$true;Result=$result;Attempts=$counter.Attempts}
        }
        $report.Success | Should -BeTrue
        $report.Result | Should -Be 'recuperado'
        $report.Attempts | Should -Be 2
    }
    It 'propaga falha do processo filho e remove o job mesmo em erro' {
        $before = @(Get-Job).Count
        { Invoke-CleanupIsolated -Action { throw 'AADSTS700027: teste' } } | Should -Throw '*AADSTS700027*'
        @(Get-Job).Count | Should -Be $before
    }
    It 'valida conexao e biblioteca dentro do processo PnP' {
        . (Join-Path $PSScriptRoot '../scripts/Configuration.ps1')
        # Fake PnP module in a real child: no tenant access or credentials.
        $manifest = Join-Path $TestDrive 'PnPFixture.psm1'
        @'
function Connect-PnPOnline { param($Url,$Tenant,$ClientId,$Thumbprint,[switch]$ReturnConnection) @{Url=$Url} }
function Get-PnPWeb { param($Connection) if (-not $Connection.Url) { throw 'conexao ausente' } }
function Get-PnPList { param($Connection,$Includes) throw 'biblioteca indisponivel no filho' }
'@ | Set-Content $manifest
        $script:PnPModulePath = $manifest
        try {
            { Connect-CleanupSite -SiteUrl 'https://contoso.sharepoint.com' -Tenant contoso.onmicrosoft.com -Authentication @{ClientId='test';CertificateThumbprint='test'} } | Should -Throw '*biblioteca indisponivel no filho*'
        } finally { $script:PnPModulePath = $null }
    }
}
