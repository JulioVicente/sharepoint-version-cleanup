BeforeAll {
$emailScript = Join-Path $PSScriptRoot '..\scripts\Send-EmailReport.ps1'
$templatePath = Join-Path $PSScriptRoot '..\templates\email-template.html'

}

Describe 'Send-EmailReport.ps1' {
    It 'nao cria transporte SMTP quando email esta desabilitado' {
        $configPath = Join-Path $TestDrive 'config.json'
        @{ Email = @{ Enabled = $false } } | ConvertTo-Json -Depth 3 | Set-Content $configPath

        { & $emailScript -ConfigPath $configPath -Test } | Should -Not -Throw
    }

    It 'possui todos os marcadores exigidos no template HTML' {
        $template = Get-Content -LiteralPath $templatePath -Raw
        'STATUS','COLOR','SITE','MODE','FILES','DELETED','FREED','SKIPPED','WARNINGS','ERROR','FINISHED' |
            ForEach-Object { $template | Should -Match ([regex]::Escape("{{$_}}")) }
    }
    It 'renderiza relatorio com escape HTML e sem marcadores pendentes' {
        $cfg = Join-Path $TestDrive 'email.json'
        @{ Email = @{ Enabled = $true } } | ConvertTo-Json | Set-Content $cfg
        $report = Join-Path $TestDrive 'report.json'
        @{
            Success=$true; SiteUrl='https://contoso.sharepoint.com'; Apply=$false
            FolderServerRelativeUrl='/teste'; FilesUnchanged=0; VersionsEligible=2; BytesEligible=1024
            FilesProcessed=1; VersionsDeleted=0; BytesFreed=0; FilesSkipped=0
            Warnings=@('<script>alert(1)</script>'); Error=''; FinishedAt=(Get-Date); LogPath=''
        } | ConvertTo-Json -Depth 4 | Set-Content $report
        $preview = Join-Path $TestDrive 'preview.html'
        & $emailScript -ConfigPath $cfg -ReportPath $report -PreviewPath $preview
        $html = Get-Content $preview -Raw
        $html | Should -Not -Match '\{\{'
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'Simulacao'
    }
}

Describe 'Transporte Microsoft Graph' {
    BeforeAll {
        function Connect-PnPOnline { param($Url,$Tenant,$ClientId,$Thumbprint,[switch]$ReturnConnection) }
        function Invoke-PnPGraphMethod { param($Url,$Method,$Content,$ContentType,$Connection) }
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Connect-PnPOnline { 'app-connection' }
        Mock Invoke-PnPGraphMethod {}
        $cfg = Join-Path $TestDrive 'graph.json'
        $settings = @{
            Tenant='contoso.onmicrosoft.com'; Sites=@('https://contoso.sharepoint.com')
            Authentication=@{ClientId='11111111-1111-1111-1111-111111111111';CertificateThumbprint=('A'*40)}
            Email=@{Enabled=$true;Provider='Graph';From='operador@contoso.com';SenderUserId='22222222-2222-2222-2222-222222222222';To=@('destino@contoso.com')}
        }
        $settings | ConvertTo-Json -Depth 5 | Set-Content $cfg
    }
    It 'envia pela caixa identificada no login usando certificado e HTML' {
        & $emailScript -ConfigPath $cfg -Test
        Should -Invoke Connect-PnPOnline -Times 1 -ParameterFilter { $Thumbprint -eq ('A'*40) -and $ClientId -eq '11111111-1111-1111-1111-111111111111' }
        Should -Invoke Invoke-PnPGraphMethod -Times 1 -ParameterFilter {
            $body = $Content | ConvertFrom-Json
            $Url -eq 'users/22222222-2222-2222-2222-222222222222/sendMail' -and $Method -eq 'Post' -and
            $body.message.body.contentType -eq 'HTML' -and $body.saveToSentItems -and
            $body.message.toRecipients[0].emailAddress.address -eq 'destino@contoso.com'
        }
    }
    It 'nao oculta recusa do Graph e orienta consentimento' {
        Mock Invoke-PnPGraphMethod { throw '403 Forbidden' }
        { & $emailScript -ConfigPath $cfg -Test } | Should -Throw '*Mail.Send*403*'
    }
    It 'rejeita SMTP antigo com instrucao de migracao' {
        $settings.Email.Remove('Provider')
        $settings | ConvertTo-Json -Depth 5 | Set-Content $cfg
        { & $emailScript -ConfigPath $cfg -Test } | Should -Throw '*Reconfigure*Graph*'
        Should -Invoke Connect-PnPOnline -Times 0
    }
    It 'previa HTML nao autentica nem envia email' {
        & $emailScript -ConfigPath $cfg -Test -PreviewPath (Join-Path $TestDrive 'graph-preview.html')
        Should -Invoke Connect-PnPOnline -Times 0
        Should -Invoke Invoke-PnPGraphMethod -Times 0
    }
    It 'inclui log pequeno como anexo Graph' {
        $log = Join-Path $TestDrive 'audit.jsonl'
        'evento de auditoria' | Set-Content $log
        $report = Join-Path $TestDrive 'graph-report.json'
        @{
            Success=$true; SiteUrl='https://contoso.sharepoint.com'; Apply=$false
            FolderServerRelativeUrl='/teste'; FilesUnchanged=0; VersionsEligible=2; BytesEligible=1024
            FilesProcessed=1; VersionsDeleted=0; BytesFreed=0; FilesSkipped=0
            Warnings=@(); Error=''; FinishedAt=(Get-Date); LogPath=$log
        } | ConvertTo-Json -Depth 4 | Set-Content $report
        & $emailScript -ConfigPath $cfg -ReportPath $report
        Should -Invoke Invoke-PnPGraphMethod -Times 1 -ParameterFilter {
            $body = $Content | ConvertFrom-Json
            $body.message.attachments[0].name -eq 'audit.jsonl' -and
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body.message.attachments[0].contentBytes)) -match 'evento de auditoria'
        }
    }
}
