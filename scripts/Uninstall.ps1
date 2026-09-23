#requires -Version 7.4.6
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$InstallPath = "$env:ProgramData\SharePointVersionCleanup",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Assert-UninstallPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\')) {
        throw '[SPVC-UNINSTALL-PATH] Informe uma pasta local absoluta e dedicada.'
    }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $protected = @([IO.Path]::GetPathRoot($root), $env:USERPROFILE, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot,
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'))
    foreach ($value in $protected) {
        if ($value -and $root -eq ([IO.Path]::GetFullPath($value).TrimEnd('\','/'))) {
            throw '[SPVC-UNINSTALL-PATH] Escolha a subpasta dedicada da instalacao, nunca uma pasta do sistema ou do usuario.'
        }
    }
    $cursor = $root
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "[SPVC-UNINSTALL-PATH] Caminho nao e uma pasta sem redirecionamento: $cursor"
            }
        }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) { throw '[SPVC-UNINSTALL-PATH] A desinstalacao nao pode atuar dentro de um repositorio Git.' }
        $cursor = Split-Path $cursor -Parent
    }
    return $root
}

function Assert-UninstallTarget {
    param([string]$Root, [string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "[SPVC-UNINSTALL-PATH] Alvo fora da instalacao: $fullPath"
    }
    $cursor = $fullPath
    while ($cursor -and $cursor -ne $Root) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "[SPVC-UNINSTALL-PATH] Redirecionamento detectado: $cursor"
            }
        }
        $cursor = Split-Path $cursor -Parent
    }
    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        foreach ($entry in Get-ChildItem -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "[SPVC-UNINSTALL-PATH] Redirecionamento detectado: $($entry.FullName)"
            }
        }
    }
}

function Get-UninstallPlan {
    param([string]$InstallPath)
    $root = Assert-UninstallPath $InstallPath
    # Fixed allowlist: never trust paths supplied by an installed manifest or JSON.
    $owned = @(
        'scripts/cleanup-versions.ps1','scripts/Send-EmailReport.ps1','scripts/Configuration.ps1',
        'scripts/Diagnostics.ps1','scripts/Progress.ps1','scripts/Formatting.ps1','scripts/TaskIdentity.ps1',
        'scripts/Test-ServiceContext.ps1','scripts/Resilience.ps1','scripts/Sampling.ps1',
        'scripts/Get-DailyAudit.ps1','scripts/Invoke-Pilot.ps1','scripts/Enable-Production.ps1',
        'scripts/Validate-Prerequisites.ps1','scripts/Uninstall.ps1',
        'config/config.example.json','config/config.json','config/wizard-defaults.json',
        'config/wizard-defaults.json.tmp','templates/email-template.html',
        'CONFIGURATION.md','QUICK_START.md','TROUBLESHOOTING.md','INSTALL_DETAILS.md','release-manifest.json','state'
    )
    $paths = @()
    foreach ($relative in $owned) {
        $target = Join-Path $root $relative
        Assert-UninstallTarget -Root $root -Path $target
        if (Test-Path -LiteralPath $target) {
            if ($relative -ne 'state' -and (Get-Item -LiteralPath $target).PSIsContainer) { throw "[SPVC-UNINSTALL-PATH] Era esperado um arquivo: $target" }
            $paths += [pscustomobject]@{ Relative = $relative; FullName = $target }
        }
    }
    $configPath = Join-Path $root 'config\config.json'
    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object {
        $_.TaskName -like 'SharePoint Version Cleanup - *' -and @($_.Actions | Where-Object {
            $_.Arguments -and $_.Arguments.Contains("`"$configPath`"", [StringComparison]::OrdinalIgnoreCase)
        }).Count
    })
    foreach ($task in $tasks) {
        if ($task.State -eq 'Running') { throw "[SPVC-UNINSTALL-BUSY] Aguarde a tarefa '$($task.TaskName)' terminar." }
        if (@($task.Actions).Count -ne 1) { throw "[SPVC-UNINSTALL-TASK] Tarefa '$($task.TaskName)' tem acoes adicionais; revise-a manualmente." }
    }
    $recognized = $tasks.Count -gt 0
    foreach ($relative in 'release-manifest.json','config/config.json','config/wizard-defaults.json') {
        $file = Join-Path $root $relative
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try {
                $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if (($relative -eq 'release-manifest.json' -and $data.Algorithm -eq 'SHA256' -and $data.Files -and $data.Files.ContainsKey('scripts/cleanup-versions.ps1')) -or
                    ($relative -eq 'config/config.json' -and $data.SchemaVersion -eq 2 -and $data.Sites -and $data.Authentication) -or
                    ($relative -eq 'config/wizard-defaults.json' -and $data.SchemaVersion -eq 1 -and $data.Values -and $data.Values.ContainsKey('Sites'))) { $recognized = $true }
            } catch { Write-Verbose "Identificacao indisponivel em ${file}: $($_.Exception.Message)" }
        }
    }
    if ($paths.Count -and -not $recognized) {
        throw '[SPVC-UNINSTALL-PATH] Pasta nao reconhecida como instalacao SharePoint Version Cleanup. Confira -InstallPath; nenhum arquivo foi movido.'
    }
    if (Test-Path -LiteralPath (Join-Path $root '.install-recovery.json')) {
        throw '[SPVC-RECOVERY] Ha uma recuperacao de instalacao pendente. Preserve e revise .install-recovery.json e os backups antes de limpar.'
    }
    return [pscustomobject]@{ Root = $root; Paths = $paths; Tasks = $tasks }
}

function Assert-UninstallAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra PowerShell como Administrador para desinstalar.' }
}

function Protect-UninstallBackup {
    param([string]$Path)
    $entries = @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    foreach ($entry in $entries) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '[SPVC-UNINSTALL-PATH] Redirecionamento inesperado no backup.' }
        $acl = if ($entry.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
            $identity = [Security.Principal.SecurityIdentifier]::new($sid)
            $rule = if ($entry.PSIsContainer) {
                [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            } else { [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow') }
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $entry.FullName -AclObject $acl -ErrorAction Stop
    }
}

function Invoke-CleanupUninstall {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$InstallPath = "$env:ProgramData\SharePointVersionCleanup", [switch]$Force)
    $plan = Get-UninstallPlan $InstallPath
    if (-not $plan.Paths.Count -and -not $plan.Tasks.Count) {
        Write-Host "Nenhum componente ou tarefa desta instalacao encontrado em $($plan.Root)."
        return
    }
    $backup = "$($plan.Root)-uninstalled-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    if ((Split-Path $backup -Parent) -ne (Split-Path $plan.Root -Parent)) { throw '[SPVC-UNINSTALL-PATH] Destino de backup invalido.' }
    Write-Host "Instalacao: $($plan.Root)"
    Write-Host "Arquivar $($plan.Paths.Count) componentes/configuracao/estado em: $backup"
    foreach ($task in $plan.Tasks) { Write-Host "Remover tarefa: $($task.TaskName)" }
    Write-Host 'Logs, auditoria, certificados, caminhos personalizados e arquivos nao reconhecidos permanecem no local. Modulos, PowerShell e Microsoft 365 nao serao removidos.'
    if ($Force) { $ConfirmPreference = 'None' }
    if (-not $PSCmdlet.ShouldProcess($plan.Root, 'Desinstalar tarefas e arquivar componentes locais')) {
        if ($WhatIfPreference) { return }
        throw '[SPVC-UNINSTALL-CANCELLED] Desinstalacao cancelada. Uma instalacao limpa nao deve continuar.'
    }
    Assert-UninstallAdministrator
    $lock = $null
    $journal = $null
    $record = [ordered]@{ InstallPath=$plan.Root; BackupPath=$backup; StartedAt=[datetime]::UtcNow.ToString('o'); FinishedAt=$null;
        Status='Started'; PlannedPaths=@($plan.Paths | ForEach-Object Relative); PlannedTasks=@($plan.Tasks | ForEach-Object TaskName);
        Archived=@(); RemovedTasks=@(); DisabledTasks=@(); Error=$null }
    try {
        if (-not (Test-Path -LiteralPath $plan.Root)) { throw '[SPVC-UNINSTALL-PATH] Pasta desapareceu durante a verificacao.' }
        Assert-UninstallTarget -Root $plan.Root -Path (Join-Path $plan.Root '.install.lock')
        try { $lock = [IO.File]::Open((Join-Path $plan.Root '.install.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw '[SPVC-UNINSTALL-BUSY] Outra instalacao/desinstalacao pode estar em curso ou o lock esta inacessivel.' }
        # Refuse an active manual cleanup too; never force-stop a running operation.
        $state = Join-Path $plan.Root 'state'
        if (Test-Path -LiteralPath $state -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $state -Filter '*.lock' -File -Recurse) {
                $probe = $null
                try { $probe = [IO.File]::Open($file.FullName, 'Open', 'ReadWrite', 'None') }
                catch { throw "[SPVC-UNINSTALL-BUSY] Limpeza ativa ou lock inacessivel: $($file.FullName)" }
                finally { if ($probe) { $probe.Dispose() } }
            }
        }
        $null = New-Item -ItemType Directory -Path $backup -ErrorAction Stop
        Protect-UninstallBackup $backup
        $journal = Join-Path $backup 'uninstall-summary.json'
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8
        # Export every task before disabling any. Never re-enable deletion tasks on failure.
        for ($i = 0; $i -lt $plan.Tasks.Count; $i++) {
            $task = $plan.Tasks[$i]
            Export-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop |
                Set-Content -LiteralPath (Join-Path $backup "task-$i.xml") -Encoding utf8
        }
        foreach ($task in $plan.Tasks) {
            $null = Disable-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop
            $record.DisabledTasks += $task.TaskName
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8
            if ((Get-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -ErrorAction Stop).State -eq 'Running') {
                throw "[SPVC-UNINSTALL-BUSY] A tarefa '$($task.TaskName)' iniciou durante a preparacao. Aguarde sua conclusao."
            }
        }
        foreach ($entry in $plan.Paths) {
            # Recheck absolute paths immediately before each move, without shell expansion.
            $null = Assert-UninstallPath $plan.Root
            Assert-UninstallTarget -Root $plan.Root -Path $entry.FullName
            $destination = [IO.Path]::GetFullPath((Join-Path $backup $entry.Relative))
            if (-not $destination.StartsWith("$backup\", [StringComparison]::OrdinalIgnoreCase)) { throw '[SPVC-UNINSTALL-PATH] Destino fora do backup.' }
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Move-Item -LiteralPath $entry.FullName -Destination $destination -ErrorAction Stop
            $record.Archived += $entry.Relative
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8
        }
        foreach ($task in $plan.Tasks) {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
            $record.RemovedTasks += $task.TaskName
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8
        }
        # Moves on the same volume retain old ACLs: remove service write access from archived state.
        Protect-UninstallBackup $backup
        $record.Status = 'Completed'
        $record.FinishedAt = [datetime]::UtcNow.ToString('o')
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8
        Write-Host "Desinstalacao concluida. Backup e registro: $backup"
        Write-Host 'Uma instalacao limpa iniciara um novo ciclo incremental. Arquivos e versoes no SharePoint nao foram alterados.'
    } catch {
        if ($journal) {
            $record.Status = 'Failed'; $record.Error = $_.Exception.Message; $record.FinishedAt = [datetime]::UtcNow.ToString('o')
            try { $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $journal -Encoding utf8 } catch { Write-Warning 'Nao foi possivel atualizar o registro da desinstalacao.' }
            try { Protect-UninstallBackup $backup } catch { Write-Warning "Revise as permissoes do backup parcial: $($_.Exception.Message)" }
        }
        throw "[SPVC-UNINSTALL] Nao concluido. Preserve o backup, se criado: $backup. Tarefas ja desabilitadas permanecem desabilitadas. Causa: $($_.Exception.Message)"
    } finally { if ($lock) { $lock.Dispose() } }
}

# Dot-sourcing exposes functions for tests without inspecting or changing the machine.
if ($MyInvocation.InvocationName -ne '.') { Invoke-CleanupUninstall @PSBoundParameters }
