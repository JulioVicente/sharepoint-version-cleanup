BeforeAll {
    . (Join-Path $PSScriptRoot '../Install.ps1') -WhatIf
}
Describe 'Sugestoes persistentes do assistente' {
    BeforeEach {
        $destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $destination 'config') -Force
        $configPath = Join-Path $destination 'config/config.json'
        $historyPath = Join-Path $destination 'config/wizard-defaults.json'
        Mock Read-Host { '' }
    }
    It 'carrega os valores anteriores e aceita Enter passando pela validacao' {
        @{ Sites=@('https://contoso.sharepoint.com');VersionsToKeep=17;Safety=@{MinimumVersionAgeDays=0};Schedule=@{Time='18:30'};Email=@{Enabled=$false;To=@('a@contoso.com','b@contoso.com')};Authentication=@{Password='never-save'} } |
            ConvertTo-Json -Depth 5 | Set-Content $configPath
        Initialize-CleanupWizardDefaults $destination
        Read-Validated -Prompt 'Retencao' -PreferenceKey VersionsToKeep -Default 10 -Validate { param($v) [int]$v } | Should -Be 17
        Read-Validated -Prompt 'Idade' -PreferenceKey Safety.MinimumVersionAgeDays -Default 30 -Validate { param($v) [int]$v } | Should -Be 0
        Read-YesNo 'Email?' -PreferenceKey Email.Enabled -Default $true | Should -BeFalse
        Read-Validated -Prompt 'Destinatarios' -PreferenceKey Email.To -Validate { param($v) $v } | Should -Be 'a@contoso.com, b@contoso.com'
        Get-Content $historyPath -Raw | Should -Not -Match 'Password|never-save|Authentication'
    }
    It 'prefere a ultima tentativa e permite substituir a sugestao' {
        @{VersionsToKeep=10} | ConvertTo-Json | Set-Content $configPath
        Initialize-CleanupWizardDefaults $destination
        Mock Read-Host { '23' }
        Read-Validated -Prompt 'Retencao' -PreferenceKey VersionsToKeep -Validate { param($v) [int]$v } | Should -Be 23
        Initialize-CleanupWizardDefaults $destination
        Mock Read-Host { '' }
        Read-Validated -Prompt 'Retencao' -PreferenceKey VersionsToKeep -Validate { param($v) [int]$v } | Should -Be 23
    }
    It 'nao grava entradas invalidas nem aprovacoes de exclusao' {
        Initialize-CleanupWizardDefaults $destination
        $script:answers = [Collections.Generic.Queue[string]]::new()
        $script:answers.Enqueue('invalido'); $script:answers.Enqueue('5')
        Mock Read-Host { $script:answers.Dequeue() }
        Read-Validated -Prompt 'Retencao' -PreferenceKey VersionsToKeep -Validate { param($v) [int]$v } | Should -Be 5
        Mock Read-Host { 'S' }
        Read-YesNo 'Aprovar exclusao?' -PreferenceKey Apply | Should -BeTrue
        Save-CleanupWizardPreference -Key Password -Value secret
        $raw = Get-Content $historyPath -Raw
        $raw | Should -Not -Match 'invalido|Apply|Password|secret'
        ($raw | ConvertFrom-Json).Values.VersionsToKeep | Should -Be 5
    }
    It 'carrega pastas por site sem mistura e mantem auditoria desativada' {
        @{FolderScopes=@{'https://a.sharepoint.com'='/docs';'https://b.sharepoint.com'='/outra'};Audit=@{CopyDirectory=''}} | ConvertTo-Json | Set-Content $configPath
        Initialize-CleanupWizardDefaults $destination
        Read-Validated -Prompt 'Pasta A' -PreferenceKey 'Folder:https://a.sharepoint.com' -Validate { param($v) $v } | Should -Be '/docs'
        Read-Validated -Prompt 'Pasta B' -PreferenceKey 'Folder:https://b.sharepoint.com' -Validate { param($v) $v } | Should -Be '/outra'
        Read-Validated -Prompt 'Auditoria' -PreferenceKey Audit.CopyDirectory -Default 'C:\audit' -Validate { param($v) $v } | Should -Be '-'
    }
    It 'historico corrompido nao bloqueia configuracao anterior' {
        @{VersionsToKeep=9} | ConvertTo-Json | Set-Content $configPath
        '{invalid' | Set-Content $historyPath
        Initialize-CleanupWizardDefaults $destination -WarningAction SilentlyContinue
        Read-Validated -Prompt 'Retencao' -PreferenceKey VersionsToKeep -Validate { param($v) [int]$v } | Should -Be 9
    }
}
