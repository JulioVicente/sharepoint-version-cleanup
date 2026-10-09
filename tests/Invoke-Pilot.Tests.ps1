BeforeAll {
    $pilotScript = Join-Path $PSScriptRoot '..\scripts\Invoke-Pilot.ps1'
}

Describe 'Invoke-Pilot.ps1' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $caseRoot | Out-Null
        $configPath = Join-Path $caseRoot 'config.json'
        @{
            Tenant = 'contoso.onmicrosoft.com'
            Sites = @('https://contoso.sharepoint.com/sites/test')
            VersionsToKeep = 2
            Authentication = @{ ClientId = '11111111-1111-1111-1111-111111111111'; CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567' }
            Paths = @{ Logs = (Join-Path $caseRoot 'logs'); State = (Join-Path $caseRoot 'state') }
            Email = @{ Enabled = $false }
            Sampling = @{ Enabled = $false }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8

        # Declara os comandos para que esta suite rode mesmo sem PnP.PowerShell instalado.
        function global:Connect-PnPOnline { param($Url,$ClientId,$Tenant,$Thumbprint,[switch]$ReturnConnection) }
        function global:Get-PnPList { param($Connection,$Includes,$Identity,[switch]$ThrowExceptionIfListNotFound) }
        function global:Get-PnPListItem { param($List,$PageSize,$Fields,$Connection,$FolderServerRelativeUrl) }
        function global:Get-PnPFolder { param($Url,$Connection) }
        function global:Get-PnPFile { param($Url,[switch]$AsFileObject,$Connection) }
        function global:Get-PnPProperty { param($ClientObject,$Property,$Connection) }
        function global:Get-PnPFileVersion { param($Url,$Connection) }
        function global:Remove-PnPFileVersion { param($Url,$Identity,[switch]$Force,$Connection) }

        Mock Import-Module {}
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Connect-PnPOnline { 'connection' }
        Mock Get-PnPList { [pscustomobject]@{ Id = 'docs'; Title = 'Documents'; BaseTemplate = 101; Hidden = $false; IsCatalog = $false } }
        Mock Get-PnPListItem { @{ FSObjType = 0; FileRef = '/sites/test/docs/a.docx'; FileLeafRef = 'a.docx' } }
        Mock Get-PnPFile { [pscustomobject]@{ CheckOutType = 'None' } }
        Mock Get-PnPProperty {}
        Mock Get-PnPFolder { [pscustomobject]@{ Name = 'docs' } }
        Mock Get-PnPFileVersion {
            @(
                [pscustomobject]@{ Id = 3; Created = [datetime]'2026-03-01'; Size = 30 }
                [pscustomobject]@{ Id = 2; Created = [datetime]'2026-02-01'; Size = 20 }
                [pscustomobject]@{ Id = 1; Created = [datetime]'2026-01-01'; Size = 10 }
            )
        }
        Mock Remove-PnPFileVersion {}
    }

    AfterEach {
        'Connect-PnPOnline','Get-PnPList','Get-PnPListItem','Get-PnPFile','Get-PnPProperty',
        'Get-PnPFileVersion','Remove-PnPFileVersion','Get-PnPFolder' | ForEach-Object {
            Remove-Item -Path "function:global:$_" -ErrorAction SilentlyContinue
        }
    }

    It 'aceita a URL do site cadastrado digitada com outra capitalizacao e barra final' {
        { & $pilotScript -ConfigPath $configPath -SiteUrl 'https://Contoso.SharePoint.com/sites/Test/' `
            -FolderServerRelativeUrl '/sites/test/docs' } | Should -Not -Throw
        Should -Invoke Connect-PnPOnline -Times 1
    }

    It 'continua recusando site que nao esta cadastrado' {
        { & $pilotScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/outro' `
            -FolderServerRelativeUrl '/sites/outro/docs' } | Should -Throw '*cadastrado*'
        Should -Invoke Connect-PnPOnline -Times 0
    }

    It 'recusa URL que nao e um site SharePoint HTTPS valido' {
        { & $pilotScript -ConfigPath $configPath -SiteUrl 'http://contoso.sharepoint.com/sites/test' `
            -FolderServerRelativeUrl '/sites/test/docs' } | Should -Throw '*invalida*'
        Should -Invoke Connect-PnPOnline -Times 0
    }

    It 'exige a confirmacao exata antes de aplicar' {
        { & $pilotScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' `
            -FolderServerRelativeUrl '/sites/test/docs' -Apply -Confirmation 'aplicar no site piloto' } |
            Should -Throw '*APLICAR NO SITE PILOTO*'
        Should -Invoke Remove-PnPFileVersion -Times 0
    }
}
