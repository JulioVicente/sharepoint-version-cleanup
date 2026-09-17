BeforeAll {
$cleanupScript = Join-Path $PSScriptRoot '..\scripts\cleanup-versions.ps1'

}

Describe 'cleanup-versions.ps1' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $caseRoot | Out-Null
        $logs = Join-Path $caseRoot 'logs'
        $state = Join-Path $caseRoot 'state'
        $configPath = Join-Path $caseRoot 'config.json'
        @{
            Tenant = 'contoso.onmicrosoft.com'
            Sites = @('https://contoso.sharepoint.com/sites/test')
            VersionsToKeep = 2
            Authentication = @{ ClientId = '11111111-1111-1111-1111-111111111111'; CertificateThumbprint = '0123456789ABCDEF0123456789ABCDEF01234567' }
            Paths = @{ Logs = $logs; State = $state }
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
        Mock Get-PnPListItem { @{ FSObjType = 0; FileRef = '/docs/a.docx'; FileLeafRef = 'a.docx' } }
        Mock Get-PnPFile { [pscustomobject]@{ CheckOutType = 'None' } }
        Mock Get-PnPProperty {}
        Mock Get-PnPFolder { [pscustomobject]@{ Name = 'docs' } }
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
        'Get-PnPFileVersion','Remove-PnPFileVersion','Get-PnPFolder' | ForEach-Object {
            Remove-Item -Path "function:global:$_" -ErrorAction SilentlyContinue
        }
    }

    It 'rejeita JSON de configuracao invalido antes de conectar' {
        $badConfig = Join-Path $TestDrive 'invalid.json'
        '{invalid' | Set-Content -LiteralPath $badConfig
        { & $cleanupScript -ConfigPath $badConfig -SiteUrl 'https://contoso.sharepoint.com/sites/test' } | Should -Throw
        Assert-MockCalled Connect-PnPOnline 0 -Scope It
    }

    It 'mantem as versoes mais novas e apenas simula a exclusao das antigas' {
        & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -WarningAction SilentlyContinue

        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
        $report = Get-ChildItem -LiteralPath $logs -Filter 'report-*.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $report.Success | Should -Be $true
        $report.FilesProcessed | Should -Be 1
        $report.VersionsEligible | Should -Be 2
        $report.VersionsDeleted | Should -Be 0
        $report.BytesEligible | Should -Be 30
        $report.BytesFreed | Should -Be 0
    }

    It 'remove somente versoes excedentes quando Apply e informado' {
        & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply

        Assert-MockCalled Remove-PnPFileVersion 2 -Scope It
        Assert-MockCalled Remove-PnPFileVersion 1 -Scope It -ParameterFilter { $Identity -eq 2 }
        Assert-MockCalled Remove-PnPFileVersion 1 -Scope It -ParameterFilter { $Identity -eq 1 }
    }

    It 'arquiva checkpoint e reavalia arquivos quando a politica muda: <Case>' -ForEach @(
        @{Case='retencao';PreviousKeep=5;PreviousPolicy='5|30';DoApply=$false},
        @{Case='idade';PreviousKeep=2;PreviousPolicy='2|1';DoApply=$false},
        @{Case='producao';PreviousKeep=5;PreviousPolicy='5|30';DoApply=$true}
    ) {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0,16)
        $mode = if ($DoApply) { 'apply' } else { 'simulation' }
        $checkpoint = Join-Path $state "checkpoint-$siteKey-$mode-E3B0C442.json"
        @{ SiteUrl=$siteUrl;Apply=$DoApply;VersionsToKeep=$PreviousKeep;PolicyKey=$PreviousPolicy;CompletedFiles=@('/docs/a.docx') } | ConvertTo-Json | Set-Content $checkpoint
        $before = Get-FileHash $checkpoint
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl -Apply:$DoApply -PassThru
        $r.FilesProcessed | Should -Be 1
        $archives = @(Get-ChildItem $state -Filter '*.bak')
        $archives.Count | Should -Be 1
        (Get-FileHash $archives[0].FullName).Hash | Should -Be $before.Hash
        if (-not $DoApply) { Should -Invoke Remove-PnPFileVersion -Times 0 }
    }

    It 'preserva e recusa checkpoint de outro site' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0,16)
        $checkpoint = Join-Path $state "checkpoint-$siteKey-simulation-E3B0C442.json"
        @{SiteUrl='https://contoso.sharepoint.com/sites/outro';Apply=$false;VersionsToKeep=5;CompletedFiles=@()} | ConvertTo-Json | Set-Content $checkpoint
        { & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl } | Should -Throw '*Checkpoint incompativel*'
        Test-Path $checkpoint | Should -BeTrue
        @(Get-ChildItem $state -Filter '*.bak').Count | Should -Be 0
        Should -Invoke Get-PnPList -Times 0
    }

    It 'retoma depois do arquivo registrado no checkpoint' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0, 16)
        @{ SiteUrl = $siteUrl; Apply = $false; VersionsToKeep = 2; CompletedFiles = @('/docs/a.docx') } | ConvertTo-Json | Set-Content (Join-Path $state "checkpoint-$siteKey-simulation-E3B0C442.json")
        Mock Get-PnPListItem {
            @(
                @{ FSObjType = 0; FileRef = '/docs/a.docx' }
                @{ FSObjType = 0; FileRef = '/docs/b.docx' }
            )
        }

        & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl -WarningAction SilentlyContinue

        Assert-MockCalled Get-PnPFile 1 -Scope It -ParameterFilter { $Url -eq '/docs/b.docx' }
        Assert-MockCalled Get-PnPFile 0 -Scope It -ParameterFilter { $Url -eq '/docs/a.docx' }
        Test-Path (Join-Path $state "checkpoint-$siteKey-simulation-E3B0C442.json") | Should -Be $false
    }

    It 'recusa uma segunda execucao quando o lock esta em uso' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $siteUrl = 'https://contoso.sharepoint.com/sites/test'
        $siteKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($siteUrl))).Substring(0, 16)
        $lockPath = Join-Path $state "cleanup-$siteKey.lock"
        $heldLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            { & $cleanupScript -ConfigPath $configPath -SiteUrl $siteUrl } | Should -Throw '*lock*'
            Assert-MockCalled Connect-PnPOnline 0 -Scope It
        } finally {
            $heldLock.Dispose()
        }
    }
    It 'rejeita retencao zero antes de conectar' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $cfg.VersionsToKeep = 0
        $cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw '*VersionsToKeep*'
        Assert-MockCalled Connect-PnPOnline 0 -Scope It
    }

    It 'rejeita site fora da lista permitida' {
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/outro' -Apply } | Should -Throw '*cadastrado*'
        Assert-MockCalled Connect-PnPOnline 0 -Scope It
    }

    It 'executa sem JSON e limita arquivos por fronteira de pasta' {
        Mock Get-PnPList { throw 'Acesso negado na enumeracao geral' } -ParameterFilter { -not $Identity }
        Mock Get-PnPListItem {
            @(
                @{ FSObjType = 0; FileRef = '/sites/test/docs/a.docx' }
                @{ FSObjType = 0; FileRef = '/sites/test/docs/sub/b.docx' }
                @{ FSObjType = 0; FileRef = '/sites/test/docs-outro/c.docx' }
            )
        }
        $r = & $cleanupScript -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Directory '/sites/test/docs' `
            -Tenant 'contoso.onmicrosoft.com' -ClientId '11111111-1111-1111-1111-111111111111' `
            -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567' -VersionsToKeep 2 -OutputDirectory $TestDrive -PassThru
        $r.FilesProcessed | Should -Be 2
        $r.VersionsEligible | Should -Be 4
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
        Assert-MockCalled Get-PnPFile 0 -Scope It -ParameterFilter { $Url -like '*docs-outro*' }
        Should -Invoke Get-PnPList -Times 1 -ParameterFilter { $Identity -eq '/sites/test/docs' -and $ThrowExceptionIfListNotFound }
        Should -Invoke Get-PnPList -Times 0 -ParameterFilter { -not $Identity }
        Should -Invoke Get-PnPListItem -Times 1 -ParameterFilter { $FolderServerRelativeUrl -eq '/sites/test/docs' }
    }

    It 'ignora checkout e rotulos mas aceita compliance flags zero' {
        Mock Get-PnPListItem {
            @(
                @{ FSObjType = 0; FileRef = '/docs/a.docx'; _ComplianceFlags = '0' }
                @{ FSObjType = 0; FileRef = '/docs/b.docx'; _ComplianceTag = 'retencao' }
                @{ FSObjType = 0; FileRef = '/docs/c.docx' }
            )
        }
        Mock Get-PnPFile { [pscustomobject]@{ CheckOutType = 'Online' } } -ParameterFilter { $Url -eq '/docs/c.docx' }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -PassThru
        $r.FilesProcessed | Should -Be 1
        $r.FilesSkipped | Should -Be 2
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
    }

    It 'preserva versao atual mesmo se o provedor a retornar' {
        Mock Get-PnPFileVersion {
            @(
                [pscustomobject]@{ Id=9; Created=[datetime]'2026-01-01'; Size=100; IsCurrentVersion=$true }
                [pscustomobject]@{ Id=3; Created=[datetime]'2026-03-01'; Size=30; IsCurrentVersion=$false }
                [pscustomobject]@{ Id=2; Created=[datetime]'2026-02-01'; Size=20; IsCurrentVersion=$false }
                [pscustomobject]@{ Id=1; Created=[datetime]'2026-01-01'; Size=10; IsCurrentVersion=$false }
            )
        }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.VersionsDeleted | Should -Be 1
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It -ParameterFilter { $Identity -eq 9 }
    }

    It 'mantem checkpoint na falha e tenta o arquivo novamente' {
        Mock Get-PnPListItem { @(@{FSObjType=0;FileRef='/docs/a.docx'}, @{FSObjType=0;FileRef='/docs/b.docx'}) }
        Mock Get-PnPFileVersion { throw 'erro temporario' } -ParameterFilter { $Url -eq '/docs/b.docx' }
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw '*erro temporario*'
        $cp = Get-ChildItem $state -Filter 'checkpoint-*.json'
        $saved = Get-Content $cp.FullName -Raw | ConvertFrom-Json
        @($saved.CompletedFiles) | Should -Contain '/docs/a.docx'
        @($saved.CompletedFiles) | Should -Not -Contain '/docs/b.docx'
        Mock Get-PnPFileVersion { @() } -ParameterFilter { $Url -eq '/docs/b.docx' }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.Success | Should -BeTrue
        $r.FilesProcessed | Should -Be 1
    }

    It 'nao reutiliza checkpoint de simulacao na aplicacao' {
        Mock Get-PnPListItem { @(@{FSObjType=0;FileRef='/docs/a.docx'}, @{FSObjType=0;FileRef='/docs/b.docx'}) }
        Mock Get-PnPFileVersion { throw 'falha simulada' } -ParameterFilter { $Url -eq '/docs/b.docx' }
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' } | Should -Throw
        Mock Get-PnPFileVersion { @() } -ParameterFilter { $Url -eq '/docs/b.docx' }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 2
        $r.VersionsDeleted | Should -Be 2
    }

    It 'execucao incremental pula historico inalterado e reprocessa mudancas' {
        Mock Get-PnPListItem { @{ FSObjType=0; FileRef='/docs/a.docx'; Modified=[datetime]'2026-09-01'; UniqueId='file-a'; _UIVersionString='5.0' } }
        $null = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesUnchanged | Should -Be 1
        $r.VersionsDeleted | Should -Be 0
        Assert-MockCalled Get-PnPFileVersion 1 -Scope It
        Assert-MockCalled Get-PnPFile 1 -Scope It
        Assert-MockCalled Get-PnPProperty 1 -Scope It
        Mock Get-PnPListItem { @{ FSObjType=0; FileRef='/docs/a.docx'; Modified=[datetime]'2026-09-02'; UniqueId='file-a'; _UIVersionString='6.0' } }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 1
        Assert-MockCalled Get-PnPFileVersion 2 -Scope It
    }

    It 'mudanca de retencao invalida inventario incremental' {
        Mock Get-PnPListItem { @{ FSObjType=0; FileRef='/docs/a.docx'; Modified=[datetime]'2026-09-01'; UniqueId='file-a'; _UIVersionString='5.0' } }
        $null = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        $cfg.VersionsToKeep = 1
        $cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 1
        $r.VersionsDeleted | Should -Be 3
    }
    It 'audita decisao e cada versao simulada sem relatar exclusao' {
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -PassThru
        $events = @(Get-Content $r.AuditPaths | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object Event -eq 'DirectoryScanned').Count | Should -Be 1
        @($events | Where-Object Event -eq 'VersionWouldDelete').Count | Should -Be 2
        @($events | Where-Object Event -eq 'VersionDeleted').Count | Should -Be 0
        $decision = $events | Where-Object Event -eq 'RetentionDecision'
        @($decision.Details.KeptVersionIds) | Should -Contain '4'
        @($decision.Details.EligibleVersionIds) | Should -Contain '1'
        $decision.Details.CurrentVersionPreserved | Should -BeTrue
        ($events | Where-Object Event -eq 'RunCompleted').Outcome | Should -Be 'Success'
        $summary = & (Join-Path $PSScriptRoot '../scripts/Get-DailyAudit.ps1') -LogsPath $logs -OutputCsv (Join-Path $TestDrive 'audit.csv')
        $summary.VersionsSimulated | Should -Be 2
        $summary.VersionsDeleted | Should -Be 0
    }

    It 'continua apos falha de exclusao, registra causa e retoma somente pendente' {
        Mock Get-PnPListItem { @(@{FSObjType=0;FileRef='/docs/a.docx'}, @{FSObjType=0;FileRef='/docs/b.docx'}) }
        Mock Remove-PnPFileVersion { throw 'acesso negado' } -ParameterFilter { $Url -eq '/docs/a.docx' }
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw '*parcial*'
        Assert-MockCalled Remove-PnPFileVersion 2 -Scope It -ParameterFilter { $Url -eq '/docs/b.docx' }
        $events = @(Get-Content (Join-Path $logs 'audit-*.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object Event -eq 'VersionDeleteFailed').Count | Should -Be 1
        ($events | Where-Object Event -eq 'VersionDeleteFailed').Error | Should -Be 'acesso negado'
        @($events | Where-Object Event -eq 'VersionDeleted').Count | Should -Be 2
        ($events | Where-Object Event -eq 'RunCompleted').Outcome | Should -Be 'Failed'
        $cp = Get-Content (Get-ChildItem $state -Filter 'checkpoint-*.json').FullName -Raw | ConvertFrom-Json
        @($cp.CompletedFiles) | Should -Contain '/docs/b.docx'
        @($cp.CompletedFiles) | Should -Not -Contain '/docs/a.docx'
        Mock Remove-PnPFileVersion {} -ParameterFilter { $Url -eq '/docs/a.docx' }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 1
        $r.Success | Should -BeTrue
    }

    It 'protege versoes recentes e registra data de reavaliacao incremental' {
        Mock Get-PnPListItem { @{ FSObjType=0;FileRef='/docs/a.docx';Modified=(Get-Date);UniqueId='a';_UIVersionString='5.0' } }
        Mock Get-PnPFileVersion { 1..4 | ForEach-Object { [pscustomobject]@{Id=$_;Created=(Get-Date).AddDays(-$_);Size=10} } }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.VersionsDeleted | Should -Be 0
        $inventory = Get-Content (Get-ChildItem $state -Filter 'inventory-*.json').FullName -Raw | ConvertFrom-Json -AsHashtable
        [datetime]$inventory.Files['/docs/a.docx'].RecheckAt | Should -BeGreaterThan (Get-Date)
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
    }

    It 'limita exclusoes e conserva o arquivo incompleto para retomada' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Safety = @{MaxVersionsPerRun=1;MinimumVersionAgeDays=0}
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw
        Assert-MockCalled Remove-PnPFileVersion 1 -Scope It
        $r = Get-Content (Get-ChildItem $logs -Filter 'report-*.json').FullName -Raw | ConvertFrom-Json
        $r.LimitReached | Should -BeTrue
        $r.VersionsDeleted | Should -Be 1
        $events = Get-Content (Join-Path $logs 'audit-*.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        @($events | Where-Object Event -eq 'FileCompleted').Count | Should -Be 0
    }

    It 'copia auditoria externa ao concluir' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Audit = @{CopyDirectory = (Join-Path $caseRoot 'audit-copy')}
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -PassThru
        $r.AuditBackupError | Should -BeNullOrEmpty
        (Get-FileHash $r.AuditPaths[0]).Hash | Should -Be (Get-FileHash (Join-Path $cfg.Audit.CopyDirectory (Split-Path $r.AuditPaths[0] -Leaf))).Hash
    }

    It 'confere inalterado por amostragem sem excluir e reavalia divergencia na proxima execucao' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sampling = @{Enabled=$true;SamplesPerLibrary=1}
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        Mock Get-PnPListItem { @{FSObjType=0;FileRef='/docs/a.docx';Modified=[datetime]'2026-09-01';UniqueId='a';_UIVersionString='5.0';File_x0020_Size=1MB} }
        Mock Get-PnPFileVersion { @() }
        $null = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        Mock Get-PnPFileVersion { 1..4 | ForEach-Object { [pscustomobject]@{Id=$_;Created=[datetime]'2026-01-01';Size=10} } }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.SamplesInspected | Should -Be 1
        $r.SampleDiscrepancies | Should -Be 1
        $r.VersionsDeleted | Should -Be 0
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
        $events = Get-Content $r.AuditPaths | ForEach-Object { $_ | ConvertFrom-Json }
        ($events | Where-Object Event -eq 'SampleSelected').Details.ReadOnly | Should -BeTrue
        ($events | Where-Object Event -eq 'SampleInspected').Outcome | Should -Be 'Discrepancy'
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 1
        $r.VersionsDeleted | Should -Be 2
    }

    It 'falha na amostragem deixa arquivo pendente para retomada completa' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sampling = @{Enabled=$true}
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        Mock Get-PnPListItem { @{FSObjType=0;FileRef='/docs/a.docx';Modified=[datetime]'2026-09-01';UniqueId='a';_UIVersionString='5.0'} }
        Mock Get-PnPFileVersion { @() }
        $null = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        Mock Get-PnPFileVersion { throw 'falha na conferencia' }
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw '*falha na conferencia*'
        $cp = Get-Content (Get-ChildItem $state -Filter 'checkpoint-*.json').FullName -Raw | ConvertFrom-Json
        @($cp.CompletedFiles) | Should -Not -Contain '/docs/a.docx'
        Mock Get-PnPFileVersion { @() }
        $r = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $r.FilesProcessed | Should -Be 1
    }
    It 'persiste sorteio sem repeticao e respeita fronteira de pasta e subpastas' {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sampling = @{Enabled=$true;SamplesPerLibrary=1}
        $cfg.FolderScopes = @{'https://contoso.sharepoint.com/sites/test'='/sites/test/docs'}
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $configPath
        Mock Get-PnPListItem { @(
            @{FSObjType=0;FileRef='/sites/test/docs/a';Modified=[datetime]'2026-09-01';UniqueId='a';_UIVersionString='5.0';File_x0020_Size=1MB},
            @{FSObjType=0;FileRef='/sites/test/docs/sub/b';Modified=[datetime]'2026-09-02';UniqueId='b';_UIVersionString='5.0';File_x0020_Size=1GB},
            @{FSObjType=0;FileRef='/sites/test/docs-outro/c';Modified=[datetime]'2026-09-03';UniqueId='c';_UIVersionString='5.0';File_x0020_Size=10GB}
        ) }
        Mock Get-PnPFileVersion { @() }
        $null = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $first = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $second = & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply -PassThru
        $first.SamplesInspected | Should -Be 1
        $second.SamplesInspected | Should -Be 1
        $one = Get-Content $first.AuditPaths | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object Event -eq 'SampleSelected'
        $two = Get-Content $second.AuditPaths | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object Event -eq 'SampleSelected'
        $one.FileUrl | Should -Not -Be $two.FileUrl
        $one.Details.CycleId | Should -Be $two.Details.CycleId
        Assert-MockCalled Get-PnPFileVersion 0 -Scope It -ParameterFilter { $Url -like '*docs-outro*' }
        Assert-MockCalled Remove-PnPFileVersion 0 -Scope It
        $daily = & (Join-Path $PSScriptRoot '../scripts/Get-DailyAudit.ps1') -LogsPath $logs
        $daily.SamplesInspected | Should -Be 2
    }
    It 'continua outra biblioteca quando a enumeracao de uma falha' {
        Mock Get-PnPList { @(
            [pscustomobject]@{Id='bad';Title='Bad';BaseTemplate=101;Hidden=$false;IsCatalog=$false},
            [pscustomobject]@{Id='good';Title='Good';BaseTemplate=101;Hidden=$false;IsCatalog=$false}
        ) }
        Mock Get-PnPListItem { throw 'biblioteca indisponivel' } -ParameterFilter { $List -eq 'bad' }
        { & $cleanupScript -ConfigPath $configPath -SiteUrl 'https://contoso.sharepoint.com/sites/test' -Apply } | Should -Throw '*biblioteca indisponivel*'
        Assert-MockCalled Remove-PnPFileVersion 2 -Scope It
    }
}
