$emailScript = Join-Path $PSScriptRoot '..\scripts\Send-EmailReport.ps1'
$templatePath = Join-Path $PSScriptRoot '..\templates\email-template.html'

Describe 'Send-EmailReport.ps1' {
    It 'nao cria transporte SMTP quando email esta desabilitado' {
        $configPath = Join-Path $TestDrive 'config.json'
        @{ Email = @{ Enabled = $false } } | ConvertTo-Json -Depth 3 | Set-Content $configPath

        { & $emailScript -ConfigPath $configPath -Test } | Should Not Throw
    }

    It 'possui todos os marcadores exigidos no template HTML' {
        $template = Get-Content -LiteralPath $templatePath -Raw
        'STATUS','COLOR','SITE','MODE','FILES','DELETED','FREED','SKIPPED','WARNINGS','ERROR','FINISHED' |
            ForEach-Object { $template | Should Match ([regex]::Escape("{{$_}}")) }
    }
}
