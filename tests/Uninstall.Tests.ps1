BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Uninstall.ps1')
    foreach ($name in 'Get-ScheduledTask','Export-ScheduledTask','Disable-ScheduledTask','Unregister-ScheduledTask') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item "function:$name" { param($TaskName,$TaskPath,[switch]$Confirm) }
        }
    }
}

Describe 'Desinstalacao limitada aos componentes locais' {
    BeforeEach {
        $installation = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($folder in 'scripts','config','state','logs','audit-copy','certificates') {
            $null = New-Item -ItemType Directory -Path (Join-Path $installation $folder) -Force
        }
        foreach ($file in 'scripts/cleanup-versions.ps1','config/config.json','config/wizard-defaults.json','state/checkpoint.json',
            'logs/report.json','audit-copy/day.jsonl','certificates/backup.pfx','unrelated.txt','scripts/custom.ps1') {
            'preserve-me' | Set-Content -LiteralPath (Join-Path $installation $file)
        }
        $ownTask = [pscustomobject]@{ TaskName='SharePoint Version Cleanup - 01';State='Ready';Actions=@(@{Arguments=('-File "{0}\scripts\cleanup-versions.ps1" -ConfigPath "{0}\config\config.json"' -f $installation)}) }
        $foreignTask = [pscustomobject]@{ TaskName='SharePoint Version Cleanup - 02';State='Ready';Actions=@(@{Arguments='-ConfigPath "C:\OtherInstallation\config\config.json"'}) }
        Mock Get-ScheduledTask { param($TaskName) if ($TaskName) { $ownTask } else { @($ownTask,$foreignTask) } }
        Mock Export-ScheduledTask { '<Task />' }
        Mock Disable-ScheduledTask {}
        Mock Unregister-ScheduledTask {}
        Mock Assert-UninstallAdministrator {}
        Mock Protect-UninstallBackup {}
    }
    It 'arquiva componentes e estado e preserva logs certificados arquivos desconhecidos e outras tarefas' {
        Invoke-CleanupUninstall -InstallPath $installation -Force
        $backup = @(Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object FullName -Like "$installation-uninstalled-*")
        $backup.Count | Should -Be 1
        foreach ($file in 'scripts/cleanup-versions.ps1','config/config.json','config/wizard-defaults.json','state/checkpoint.json') {
            Test-Path -LiteralPath (Join-Path $installation $file) | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $backup[0].FullName $file) | Should -Be 'preserve-me'
        }
        foreach ($file in 'logs/report.json','audit-copy/day.jsonl','certificates/backup.pfx','unrelated.txt','scripts/custom.ps1') {
            Get-Content -LiteralPath (Join-Path $installation $file) | Should -Be 'preserve-me'
        }
        $record = Get-Content (Join-Path $backup[0].FullName 'uninstall-summary.json') -Raw | ConvertFrom-Json
        $record.Status | Should -Be 'Completed'
        $record.RemovedTasks | Should -Be @($ownTask.TaskName)
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq $ownTask.TaskName }
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
        Should -Invoke Protect-UninstallBackup -Times 2
    }
    It 'WhatIf nao cria backup lock nem desabilita tarefas' {
        Invoke-CleanupUninstall -InstallPath $installation -WhatIf
        Test-Path (Join-Path $installation '.install.lock') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object FullName -Like "$installation-uninstalled-*").Count | Should -Be 0
        Should -Invoke Assert-UninstallAdministrator -Times 0
        Should -Invoke Export-ScheduledTask -Times 0
        Should -Invoke Disable-ScheduledTask -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
    }
    It 'recusa tarefa em execucao antes de alterar arquivos' {
        $ownTask.State = 'Running'
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*SPVC-UNINSTALL-BUSY*'
        Should -Invoke Disable-ScheduledTask -Times 0
        Test-Path (Join-Path $installation 'config/config.json') | Should -BeTrue
    }
    It 'recusa tarefa que iniciou durante a preparacao' {
        Mock Disable-ScheduledTask { $ownTask.State = 'Running' }
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*iniciou durante*'
        Should -Invoke Unregister-ScheduledTask -Times 0
        Test-Path (Join-Path $installation 'config/config.json') | Should -BeTrue
    }
    It 'nao modifica tarefa com acoes adicionais' {
        $ownTask.Actions += @{Arguments='another-action'}
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*acoes adicionais*'
        Should -Invoke Disable-ScheduledTask -Times 0
    }
    It 'nao toca em recuperacao pendente' {
        'recovery' | Set-Content (Join-Path $installation '.install-recovery.json')
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*SPVC-RECOVERY*'
        Get-Content (Join-Path $installation '.install-recovery.json') | Should -Be 'recovery'
    }
    It 'recusa locks em uso de <Relative>' -ForEach @(@{Relative='.install.lock'},@{Relative='state/cleanup-site.lock'}) {
        $handle = [IO.File]::Open((Join-Path $installation $Relative), 'OpenOrCreate', 'ReadWrite', 'None')
        try { { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*SPVC-UNINSTALL-BUSY*' }
        finally { $handle.Dispose() }
        Should -Invoke Disable-ScheduledTask -Times 0
        Should -Invoke Unregister-ScheduledTask -Times 0
    }
    It 'nao move arquivos se nao puder proteger o backup' {
        Mock Protect-UninstallBackup { throw 'ACL negada' }
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*ACL negada*'
        Test-Path (Join-Path $installation 'config/config.json') | Should -BeTrue
        Should -Invoke Disable-ScheduledTask -Times 0
    }
    It 'registra falha e preserva evidencias sem reativar tarefas' {
        Mock Move-Item { throw 'disk error' }
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*disk error*'
        $backup = Get-ChildItem -LiteralPath $TestDrive -Directory | Where-Object FullName -Like "$installation-uninstalled-*"
        $record = Get-Content (Join-Path $backup.FullName 'uninstall-summary.json') -Raw | ConvertFrom-Json
        $record.Status | Should -Be 'Failed'
        $record.Error | Should -Match 'disk error'
        $record.DisabledTasks | Should -Be @($ownTask.TaskName)
        Should -Invoke Protect-UninstallBackup -Times 2
        Should -Invoke Unregister-ScheduledTask -Times 0
        Test-Path (Join-Path $installation 'config/config.json') | Should -BeTrue
    }
    It 'nao usa caminhos fornecidos por manifesto adulterado' {
        '{"Files":{"../outside.txt":"fake"}}' | Set-Content (Join-Path $installation 'release-manifest.json')
        $plan = Get-UninstallPlan $installation
        @($plan.Paths | Where-Object Relative -eq '../outside.txt').Count | Should -Be 0
        { Assert-UninstallTarget -Root $installation -Path (Join-Path $installation '../outside.txt') } | Should -Throw '*fora da instalacao*'
    }
    It 'recusa raiz do disco, pasta do usuario e caminhos relativos' {
        foreach ($path in @([IO.Path]::GetPathRoot($installation),$env:USERPROFILE,'relative')) {
            { Get-UninstallPlan $path } | Should -Throw '*SPVC-UNINSTALL-PATH*'
        }
    }
    It 'recusa repositorio Git mesmo com componentes instalados' {
        $null = New-Item -ItemType Directory -Path (Join-Path $installation '.git')
        { Get-UninstallPlan $installation } | Should -Throw '*repositorio Git*'
    }
    It 'recusa junction sem mover o destino externo' {
        $outside = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Path $outside
        'untouched' | Set-Content (Join-Path $outside 'important.txt')
        $link = Join-Path $installation 'state/link'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*Redirecionamento*'
            Get-Content (Join-Path $outside 'important.txt') | Should -Be 'untouched'
            Should -Invoke Disable-ScheduledTask -Times 0
        } finally { Remove-Item -LiteralPath $link -Force }
    }
    It 'nao exige modulo Graph nem login para instalacao ausente' {
        Mock Get-ScheduledTask { @() }
        Invoke-CleanupUninstall -InstallPath (Join-Path $TestDrive 'absent') -Force
        Should -Invoke Assert-UninstallAdministrator -Times 0
        Should -Invoke Disable-ScheduledTask -Times 0
    }
    It 'recusa pasta de outro programa com nomes de arquivo semelhantes' {
        Mock Get-ScheduledTask { @() }
        { Invoke-CleanupUninstall -InstallPath $installation -Force } | Should -Throw '*nao reconhecida*'
        Test-Path (Join-Path $installation 'config/config.json') | Should -BeTrue
        Should -Invoke Assert-UninstallAdministrator -Times 0
    }
    It 'reconhece instalacao interrompida apenas pelo historico do wizard' {
        Mock Get-ScheduledTask { @() }
        '{"SchemaVersion":1,"Values":{"Sites":["https://contoso.sharepoint.com"]}}' | Set-Content (Join-Path $installation 'config/wizard-defaults.json')
        (Get-UninstallPlan $installation).Paths.Count | Should -BeGreaterThan 0
    }
}
