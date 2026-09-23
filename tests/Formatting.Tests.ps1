BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Formatting.ps1')
}

Describe 'Tamanhos legiveis sem alterar os bytes do relatorio' {
    It 'seleciona <Unit> para <Bytes> bytes' -TestCases @(
        @{Bytes=0; Value=0; Unit='B'}
        @{Bytes=512; Value=512; Unit='B'}
        @{Bytes=1024; Value=1; Unit='KB'}
        @{Bytes=1536; Value=1.5; Unit='KB'}
        @{Bytes=1MB; Value=1; Unit='MB'}
        @{Bytes=850MB; Value=850; Unit='MB'}
        @{Bytes=1GB; Value=1; Unit='GB'}
        @{Bytes=1.25GB; Value=1.25; Unit='GB'}
        @{Bytes=(1GB - 1KB); Value=1; Unit='GB'}
        @{Bytes=1TB; Value=1; Unit='TB'}
        @{Bytes=2.5TB; Value=2.5; Unit='TB'}
        @{Bytes=[long]::MaxValue; Value=8; Unit='EB'}
    ) {
        param($Bytes, $Value, $Unit)
        Format-CleanupSize -Bytes $Bytes | Should -Be ('{0:N2} {1}' -f $Value, $Unit)
    }

    It 'respeita a cultura brasileira na parte decimal' {
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            Format-CleanupSize -Bytes 1.25GB | Should -Be '1,25 GB'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        }
    }

    It 'mostra estimativa em TB e liberado em GB no mesmo email preservando o JSON' {
        $configPath = Join-Path $TestDrive 'config.json'
        @{Email=@{Enabled=$true}} | ConvertTo-Json | Set-Content $configPath
        $reportPath = Join-Path $TestDrive 'report.json'
        @{
            Success=$true; SiteUrl='https://contoso.sharepoint.com'; Apply=$true
            FolderServerRelativeUrl='/teste'; FilesUnchanged=0; VersionsEligible=200
            BytesEligible=2.5TB; BytesFreed=1.25GB; FilesProcessed=1; VersionsDeleted=10
            FilesSkipped=0; Warnings=@(); Error=''; FinishedAt=(Get-Date); LogPath=''
        } | ConvertTo-Json | Set-Content $reportPath
        $original = Get-Content $reportPath -Raw
        $preview = Join-Path $TestDrive 'email.html'
        & (Join-Path $PSScriptRoot '../scripts/Send-EmailReport.ps1') -ConfigPath $configPath -ReportPath $reportPath -PreviewPath $preview
        $html = Get-Content $preview -Raw
        $html | Should -Match ([regex]::Escape(('{0:N2} TB' -f 2.5)))
        $html | Should -Match ([regex]::Escape(('{0:N2} GB' -f 1.25)))
        Get-Content $reportPath -Raw | Should -Be $original
    }
}
