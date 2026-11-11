BeforeAll {
    function Register-ScheduledTask { param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$Description,$Principal,[switch]$Force,$Xml) }
    $project = Split-Path $PSScriptRoot -Parent
    . (Join-Path $project 'scripts/Configuration.ps1')
    . (Join-Path $project 'scripts/TaskIdentity.ps1')
    . (Join-Path $project 'scripts/ScheduledTasks.ps1')
    . (Join-Path $project 'scripts/Reload-Configuration.ps1') -WhatIf
    $realEnvironmentValidation = (Get-Command Assert-CleanupReloadEnvironment).ScriptBlock
}
Describe 'Recarga automatica do JSON' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        $source = Join-Path $root 'config/config.json'
        $active = Join-Path $root 'config/active-config.json'
        $cfg = Get-Content (Join-Path $project 'config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $cfg.Sites = @('https://contoso.sharepoint.com')
        $cfg.FolderScopes = @{'https://contoso.sharepoint.com'=''}
        $cfg.Paths = @{State=(Join-Path $root 'state');Logs=(Join-Path $root 'logs')}
        $cfg.Audit.CopyDirectory = ''
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Copy-Item $source $active
        $before = [IO.File]::ReadAllText($active)
        $name = 'SharePoint Version Cleanup - 01'
        $original = [pscustomobject]@{TaskName=$name;State='Running';Principal=[pscustomobject]@{LogonType='ServiceAccount'};
            Actions=@([pscustomobject]@{Arguments="-ConfigPath `"$source`" -UseActiveConfiguration -SiteUrl `"https://contoso.sharepoint.com`" -Apply"})}
        $template = $original | ConvertTo-Json -Depth 8
        $store = @{Tasks=@{$name=$original}}
        Mock Get-ScheduledTask { param($TaskName) if ($TaskName) { $store.Tasks[$TaskName] } else { @($store.Tasks.Values) } }
        Mock Export-ScheduledTask { '<original-task/>' }
        Mock Disable-ScheduledTask { param($TaskName) if ($store.Tasks[$TaskName].State -ne 'Running') { $store.Tasks[$TaskName].State='Disabled' } }
        Mock Enable-ScheduledTask { param($TaskName) $store.Tasks[$TaskName].State='Ready' }
        Mock Stop-ScheduledTask { param($TaskName) $store.Tasks[$TaskName].State='Disabled' }
        Mock Start-ScheduledTask { param($TaskName) $store.Tasks[$TaskName].State='Running' }
        Mock Unregister-ScheduledTask { param($TaskName) $store.Tasks.Remove($TaskName) }
        Mock New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
        Mock New-ScheduledTaskTrigger { [pscustomobject]@{StartBoundary=[string]$At} }
        Mock New-ScheduledTaskSettingsSet { @{} }
        Mock New-ScheduledTaskPrincipal { [pscustomobject]@{LogonType='ServiceAccount'} }
        Mock Register-ScheduledTask {
            param($TaskName,$Action,$Xml,$Principal)
            if ($Xml) { $store.Tasks[$TaskName] = $template | ConvertFrom-Json; $store.Tasks[$TaskName].State='Ready' }
            else { $store.Tasks[$TaskName]=[pscustomobject]@{TaskName=$TaskName;State='Disabled';Actions=@($Action);Principal=$Principal} }
        }
        Mock Start-Sleep {}
        Mock Assert-CleanupLocalPath {}
        Mock Assert-CleanupReloadEnvironment {}
        Mock Install-CleanupServiceCertificate {}
        Mock Set-CleanupServiceAcl {}
    }
    It 'nao faz nada se o JSON nao mudou' {
        Invoke-CleanupConfigurationReload $source
        Should -Invoke Stop-ScheduledTask -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
        Test-Path (Join-Path $root 'config-reload.log') | Should -BeFalse
    }
    It 'JSON invalido registra erro e mantem configuracao ativa e execucao' {
        '{invalid' | Set-Content $source
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*JSON nao recarregado*'
        [IO.File]::ReadAllText($active) | Should -Be $before
        (Get-Content (Join-Path $root 'config-reload.log') -Raw) | Should -Match 'JSON nao recarregado por erro.*validar JSON'
        Should -Invoke Stop-ScheduledTask -Times 0
        $store.Tasks[$name].State | Should -Be 'Running'
    }
    It 'validacao semantica falha antes de parar tarefas' {
        $cfg.Schedule.Time='99:99'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*Schedule*'
        Should -Invoke Stop-ScheduledTask -Times 0
        [IO.File]::ReadAllText($active) | Should -Be $before
    }
    It 'arquivo ainda mudando nao reinicia e deixa motivo no log' {
        $cfg.Schedule.Time='21:00'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Mock Start-Sleep { Add-Content $source ' ' }
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*gravacao*'
        Should -Invoke Stop-ScheduledTask -Times 0
    }
    It 'recarrega tudo atualiza horario e reinicia com producao preservada no mesmo escopo' {
        $cfg.Schedule.Time='21:00'; $cfg.Retry.MaxRetries=4
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Invoke-CleanupConfigurationReload $source
        (Get-Content $active -Raw | ConvertFrom-Json).Retry.MaxRetries | Should -Be 4
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
        Should -Invoke New-ScheduledTaskTrigger -Times 1 -ParameterFilter { $At -eq '21:00' }
        $store.Tasks[$name].Actions[0].Arguments | Should -Match '-UseActiveConfiguration.*-Apply'
        Test-Path (Join-Path $root '.reload-recovery.json') | Should -BeFalse
        Get-Content (Join-Path $root 'config-reload.log') -Raw | Should -Match 'JSON recarregado com sucesso'
    }
    It 'mudanca de retencao nao herda aprovacao de exclusoes' {
        $cfg.VersionsToKeep=3; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Invoke-CleanupConfigurationReload $source
        $store.Tasks[$name].Actions[0].Arguments | Should -Not -Match '-Apply'
        Should -Invoke Start-ScheduledTask -Times 1
    }
    It 'tarefa desativada continua desativada apos sincronizar horario' {
        $store.Tasks[$name].State='Disabled'
        $cfg.Schedule.Time='21:00'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Invoke-CleanupConfigurationReload $source
        $store.Tasks[$name].State | Should -Be 'Disabled'
        Should -Invoke Start-ScheduledTask -Times 0
    }
    It 'falha ao registrar reverte JSON e tarefa e registra erro original' {
        $cfg.Schedule.Time='21:00'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Mock Register-ScheduledTask { throw 'acesso negado ao agendador' } -ParameterFilter { -not $Xml }
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*acesso negado*restauradas*'
        [IO.File]::ReadAllText($active) | Should -Be $before
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $Xml -eq '<original-task/>' }
        Should -Invoke Start-ScheduledTask -Times 1
        Test-Path (Join-Path $root '.reload-recovery.json') | Should -BeFalse
    }
    It 'reordenar sites reinicia o site anterior no novo numero e novos sites ficam em simulacao' {
        $cfg.Sites=@('https://new.sharepoint.com','https://contoso.sharepoint.com')
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Invoke-CleanupConfigurationReload $source
        $store.Tasks['SharePoint Version Cleanup - 02'].State | Should -Be 'Running'
        $store.Tasks['SharePoint Version Cleanup - 02'].Actions[0].Arguments | Should -Match '-Apply'
        $store.Tasks[$name].Actions[0].Arguments | Should -Not -Match '-Apply'
        Should -Invoke Start-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'SharePoint Version Cleanup - 02' }
    }
    It 'falha na segunda tarefa restaura a primeira e a configuracao anterior' {
        $cfg.Sites+=@('https://new.sharepoint.com')
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Mock Register-ScheduledTask { throw 'falha na segunda tarefa' } -ParameterFilter { $TaskName -eq 'SharePoint Version Cleanup - 02' -and -not $Xml }
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*segunda tarefa*restauradas*'
        [IO.File]::ReadAllText($active) | Should -Be $before
        $store.Tasks[$name].State | Should -Be 'Running'
        $store.Tasks.ContainsKey('SharePoint Version Cleanup - 02') | Should -BeFalse
    }
    It 'tarefa que inicia entre snapshot e parada tambem e reiniciada' {
        $store.Tasks[$name].State='Ready'
        Mock Disable-ScheduledTask { param($TaskName) $store.Tasks[$TaskName].State='Running' }
        $cfg.Schedule.Time='21:00'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        Invoke-CleanupConfigurationReload $source
        Should -Invoke Stop-ScheduledTask -Times 1
        Should -Invoke Start-ScheduledTask -Times 1
    }
    It 'recupera transacao interrompida antes de analisar nova mudanca' {
        @{ActiveText=$before;TargetNames=@($name);Tasks=@(@{Name=$name;Xml='<original-task/>';WasRunning=$true})} |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root '.reload-recovery.json')
        'broken' | Set-Content $active
        Invoke-CleanupConfigurationReload $source
        [IO.File]::ReadAllText($active) | Should -Be $before
        Test-Path (Join-Path $root '.reload-recovery.json') | Should -BeFalse
        Get-Content (Join-Path $root 'config-reload.log') -Raw | Should -Match 'recarga anterior interrompida'
    }
    It 'falha na recuperacao preserva journal e loga recuperacao incompleta' {
        @{ActiveText=$before;TargetNames=@($name);Tasks=@(@{Name=$name;Xml='<original-task/>';WasRunning=$true})} |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $root '.reload-recovery.json')
        Mock Register-ScheduledTask { throw 'restauracao negada' } -ParameterFilter { $Xml }
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*Recuperacao incompleta*'
        Test-Path (Join-Path $root '.reload-recovery.json') | Should -BeTrue
        Get-Content (Join-Path $root 'config-reload.log') -Raw | Should -Match 'recuperar recarga anterior.*restauracao negada'
    }
    It 'manifesto PnP incompativel e recusado antes da parada' {
        $modulePath = Join-Path $env:ProgramFiles 'PowerShell/Modules/PnP.PowerShell/4.0.0/PnP.PowerShell.psd1'
        $cfg.PnPModulePath = $modulePath
        Mock Get-Item { [pscustomobject]@{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)} } -ParameterFilter { $LiteralPath -like 'Cert:*' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $modulePath }
        Mock Import-PowerShellDataFile { @{ModuleVersion='4.0.0';PowerShellVersion='7.4.0'} }
        Mock Assert-CleanupReloadEnvironment { param($Configuration,$Root) & $realEnvironmentValidation -Configuration $Configuration -Root $Root }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        { Invoke-CleanupConfigurationReload $source } | Should -Throw '*PnP incompativel*'
        Should -Invoke Stop-ScheduledTask -Times 0
        [IO.File]::ReadAllText($active) | Should -Be $before
    }
    It 'instalacao em andamento impede recarga concorrente' {
        $cfg.Schedule.Time='21:00'; $cfg | ConvertTo-Json -Depth 10 | Set-Content $source
        $handle = [IO.File]::Open((Join-Path $root '.install.lock'),'OpenOrCreate','ReadWrite','None')
        try { Invoke-CleanupConfigurationReload $source } finally { $handle.Dispose() }
        Should -Invoke Stop-ScheduledTask -Times 0
        Should -Invoke Register-ScheduledTask -Times 0
    }
    It 'WhatIf nao cria lock nem log e nao altera tarefas' {
        Invoke-CleanupConfigurationReload $source -WhatIf
        Test-Path (Join-Path $root '.install.lock') | Should -BeFalse
        Should -Invoke Register-ScheduledTask -Times 0
    }
}
