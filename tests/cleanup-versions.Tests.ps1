$cleanupScript = Join-Path $PSScriptRoot '..\scripts\cleanup-versions.ps1'

Describe 'cleanup-versions.ps1' {
    BeforeEach {
        $logs = Join-Path $TestDrive 'logs'
        $state = Join-Path $TestDrive 'state'
        $configPath = Join-Path $TestDrive 'config.json'
        @{
            Tenant = 'contoso.onmicrosoft.com'
            VersionsToKeep = 2
            Authentication = @{ ClientId = 'client-id'; CertificateThumbprint = 'thumbprint' }
            Paths = @{ Logs = $logs; State = $state }
            Email = @{ Enabled = $false }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8

        # Declara os comandos para que esta suite rode mesmo sem PnP.PowerShell instalado.
        function global:Connect-PnPOnline { param($Url,$ClientId,$Tenant,$Thumbprint,[switch]$ReturnConnection) }
        function global:Get-PnPList { param($Connection) }
        function global:Get-PnPListItem { param($List,$PageSize,$Fields,$Connection) }
        function global:Get-PnPFile { param($Url,[switch]$AsFileObject,$Connection) }
        function global:Get-PnPProperty { param($ClientObject,$Property,$Connection) }
        function global:Get-PnPFileVersion { param($Url,$Connection) }
        function global:Remove-PnPFileVersion { param($Url,$Identity,[switch]$Force,$Connection) }

        Mock Import-Module {}
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Connect-PnPOnline { 'connection' }
        Mock Get-PnPList { [pscustomobject]@{ Id = 'docs'; Title = 'Documents'; BaseTemplate = 101; Hidden = $false; IsCatalog = $false } }
        Mock Get-PnPListItem { @{ FSObjType = 0; FileRef = '/docs/a.docx'; FileLeafRef = 'a.docx' } }
        Mock Get-PnPFile { [pscustomobject]@{ CheckOutType = 'None' } }
        Mock Get-PnPProperty {}
        Mock Get-PnPFileVersion {
            @(
                [pscustomobject]@{ Id = 4; Created = [datetime]'2026-04-01'; Size = 40 }
                [pscustomobject]@{ Id = 3; Created = [datetime]'2026-03-01'; Size = 30 }
                [pscustomobject]@{ Id = 2; Created = [datetime]'2026-02-01'; Size = 20 }
                [pscustomobject]@{ Id = 1; Created = [datetime]'2026-01-01'; Size = 10 }
            )
        }
        Mock Remove-PnPFileVersion {}
    }

    AfterEach {
        'Connect-PnPOnline','Get-PnPList','Get-PnPListItem','Get-PnPFile','Get-PnPProperty',
        'Get-PnPFileVersion','Remove-PnPFileVersion' | ForEach-Object {
            Remove-Item -Path "function:global:$_" -ErrorAction SilentlyContinue
        }
    }

    It 'rejeita JSON de configuracao invalido antes de conectar' {
        $badConfig = Join-Path $TestDrive 'invalid.json'
        '{invalid' | Set-Content -LiteralPath $badConfig
        { & $cleanupScript -ConfigPath $badConfig -SiteUrl 'https://contoso.sharepoint.com/sites/test' } | Should Throw
        Assert-MockCalled Connect-PnPOnline 0 -Scope It
    }

    It 'mantem as versoes mais novas e apenas simula a exclusao das antigas' {
        & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -WarningAction SilentlyContinue

        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
        $report = Get-ChildItem -LiteralPath $logs -Filter 'report-*.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $report.Success | Should Be $true
        $report.FilesProcessed | Should Be 1
        $report.VersionsDeleted | Should Be 2
        $report.BytesFreed | Should Be 30
    }

    It 'remove somente versoes excedentes quando Apply e informado' {
        & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply

        Assert-MockCalled Remove-PnPFileVersion 2 -Scope It
        Assert-MockCalled Remove-PnPFileVersion 1 -Scope It -ParameterFilter { $Identity -eq 2 }
        Assert-MockCalled Remove-PnPFileVersion 1 -Scope It -ParameterFilter { $Identity -eq 1 }
    }

    It 'retoma depois do arquivo registrado no checkpoint' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0, 16)
        @{ LastFileUrl = '/docs/a.docx' } | ConvertTo-Json | Set-Content (Join-Path $state "checkpoint-$siteKey.json")
        Mock Get-PnPListItem {
            @(
                @{ FSObjType = 0; FileRef = '/docs/a.docx' }
                @{ FSObjType = 0; FileRef = '/docs/b.docx' }
            )
        }

        & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl -WarningAction SilentlyContinue

        Assert-MockCalled Get-PnPFile 1 -Scope It -ParameterFilter { $Url -eq '/docs/b.docx' }
        Assert-MockCalled Get-PnPFile 0 -Scope It -ParameterFilter { $Url -eq '/docs/a.docx' }
        Test-Path (Join-Path $state "checkpoint-$siteKey.json") | Should Be $false
    }

    It 'recusa uma segunda execucao quando o lock esta em uso' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0, 16)
        $lockPath = Join-Path $state "cleanup-$siteKey.lock"
        $heldLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            { & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl } | Should Throw 'Ja existe uma limpeza em execucao para este site.'
            Assert-MockCalled Connect-PnPOnline 0 -Scope It
        } finally {
            $heldLock.Dispose()
        }
    }
}
