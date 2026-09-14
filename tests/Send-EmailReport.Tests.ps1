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
