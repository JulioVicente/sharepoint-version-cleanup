#requires -Version 7.4.6
function Install-ScheduledTasks {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [System.Collections.IDictionary]$Configuration,
        [string]$Destination,
        [string[]]$ProductionSites = @(),
        [switch]$KeepDisabled
    )

    Write-Host 'Atualizando tarefas agendadas...'
    $days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $cleanupScript = Join-Path $Destination 'scripts\cleanup-versions.ps1'
    $configPath = Join-Path $Destination 'config\config.json'
    Write-Host 'As tarefas usarao LOCAL SERVICE e o certificado do aplicativo, sem senha pessoal e sem exigir sessao aberta.'
    $serviceName = ([Security.Principal.SecurityIdentifier]::new('S-1-5-19')).Translate([Security.Principal.NTAccount]).Value
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $serviceName -LogonType ServiceAccount -RunLevel Limited
        for ($index = 0; $index -lt $Configuration.Sites.Count; $index++) {
            $site = $Configuration.Sites[$index]
            $day = $days[$index % $days.Count]
            $taskName = "$script:TaskPrefix - {0:D2}" -f ($index + 1)
            # Instalacoes novas iniciam deliberadamente em simulacao. O operador
            # deve validar os relatorios antes de acrescentar -Apply.
            $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cleanupScript`" -ConfigPath `"$configPath`" -UseActiveConfiguration -SiteUrl `"$site`""
            if ($Configuration.FolderScopes[$site]) { $arguments += " -FolderServerRelativeUrl `"$($Configuration.FolderScopes[$site])`"" }
            if ($site -in $ProductionSites) { $arguments += ' -Apply' }
            $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
            $trigger = if ($Configuration.Schedule.Frequency -eq 'diaria') {
                New-ScheduledTaskTrigger -Daily -At $Configuration.Schedule.Time
            } else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $day -At $Configuration.Schedule.Time }
            $settings = New-ScheduledTaskSettingsSet -Disable:$KeepDisabled -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 12) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 15)

            if ($PSCmdlet.ShouldProcess($taskName, "Agendar $site as $($Configuration.Schedule.Time)")) {
                $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($existingTask) {
                    if ($existingTask.State -eq 'Running') { throw "A tarefa $taskName esta em execucao. Aguarde antes de atualizar." }
                    if (@($existingTask.Actions).Count -ne 1 -or
                        $existingTask.Actions[0].Arguments -notlike "*`"$configPath`"*") {
                        throw "A tarefa $taskName pertence a outra configuracao. Escolha nomes/destino sem conflito."
                    }
                    if (-not $script:TaskBackups.ContainsKey($taskName)) { $script:TaskBackups[$taskName] = Export-ScheduledTask -TaskName $taskName -TaskPath '\' }
                } else {
                    $script:NewTasks.Add($taskName)
                }
                Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
                    -Settings $settings -Description "Limpeza de versoes: $site" `
                    -Principal $taskPrincipal -Force | Out-Null
            }
        }
}

