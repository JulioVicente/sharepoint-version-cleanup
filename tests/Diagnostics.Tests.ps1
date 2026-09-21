BeforeAll { . (Join-Path $PSScriptRoot '../scripts/Diagnostics.ps1') }
Describe 'Recuperacao de estado e diagnostico' {
    It 'arquiva JSON corrompido sem destruir a evidencia' {
        $path = Join-Path $TestDrive 'bad.json'
        '{truncated' | Set-Content $path
        $hash = (Get-FileHash $path).Hash
        Read-CleanupState -Path $path -Validate { $true } -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path $path | Should -BeFalse
        $backup = Get-ChildItem $TestDrive -Filter 'bad.json.invalid-*.bak'
        (Get-FileHash $backup.FullName).Hash | Should -Be $hash
    }
    It 'preserva estado valido' {
        $path = Join-Path $TestDrive 'valid.json'
        '{"Files":{}}' | Set-Content $path
        (Read-CleanupState -Path $path -Validate { param($s) $s.Files -is [Collections.IDictionary] }).ContainsKey('Files') | Should -BeTrue
        Test-Path $path | Should -BeTrue
    }
    It 'nao trata falha de leitura como corrupcao recuperavel' {
        $path = Join-Path $TestDrive 'locked.json'
        '{}' | Set-Content $path
        Mock Get-Content { throw [UnauthorizedAccessException]::new('Access denied') }
        { Read-CleanupState -Path $path -Validate { $true } } | Should -Throw '*Access denied*'
        Test-Path $path | Should -BeTrue
        @(Get-ChildItem $TestDrive -Filter 'locked.json.invalid-*.bak').Count | Should -Be 0
    }
    It 'classifica <Message> como <Code>' -ForEach @(
        @{Message='AADSTS700027 invalid certificate';Code='SPVC-CERTIFICATE'},
        @{Message='403 Forbidden';Code='SPVC-PERMISSION'},
        @{Message='401 Unauthorized';Code='SPVC-AUTH'},
        @{Message='Import-Module PnP.PowerShell';Code='SPVC-MODULE'},
        @{Message='503 Service unavailable';Code='SPVC-NETWORK'},
        @{Message='No space on disk';Code='SPVC-STORAGE'}
    ) {
        try { throw $Message } catch { Get-CleanupFailureHint $_ | Should -Match $Code }
    }
}
