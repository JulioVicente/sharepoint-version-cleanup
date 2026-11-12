#requires -Version 7.4.6
[CmdletBinding(SupportsShouldProcess)]
param([string]$ConfigPath = "$env:ProgramData\SharePointVersionCleanup\config\config.json")

function Write-CleanupReloadLog {
    param([string]$Root,[string]$Message)
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $defaultDirectory = Join-Path $Root 'logs'
    $directory = $defaultDirectory
    $diagnostics = [Collections.Generic.List[string]]::new()
    try {
        # Never take the log destination from the editable, potentially invalid JSON.
        $active = Read-CleanupConfiguration (Join-Path $Root 'config/active-config.json')
        $candidate = [IO.Path]::GetFullPath($active.Paths.Logs).TrimEnd('\')
        if (-not $candidate.StartsWith("$Root\",[StringComparison]::OrdinalIgnoreCase)) { throw 'Paths.Logs fora da instalacao.' }
        foreach ($protected in 'scripts','config','certificates') {
            $base = Join-Path $Root $protected
            if ($candidate -eq $base -or $candidate.StartsWith("$base\",[StringComparison]::OrdinalIgnoreCase)) { throw 'Paths.Logs aponta para uma pasta protegida.' }
        }
        $directory = $candidate
    } catch { $diagnostics.Add("Destino de log ativo indisponivel: $($_.Exception.Message)") }
    $line = '{0} [SPVC-CONFIG-RELOAD] {1}' -f ([DateTimeOffset]::Now.ToString('o')), $Message
    foreach ($target in @($directory,$defaultDirectory | Select-Object -Unique)) {
        try {
            $path = Join-Path $target 'config-reload.log'
            Assert-CleanupLocalPath $path
            $null = [IO.Directory]::CreateDirectory($target)
            $entry = $line
            if ($diagnostics.Count) { $entry += ' Log alternativo: ' + ($diagnostics -join ' ') }
            [IO.File]::AppendAllText($path, $entry + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
            Write-Host $entry
            return
        } catch { $diagnostics.Add("Falha em '${target}': $($_.Exception.Message)") }
    }
    throw "$line Nao foi possivel gravar o log: $($diagnostics -join ' ')"
}
function Set-CleanupActiveConfiguration {
    param([string]$Path,[string]$Text)
    [IO.File]::WriteAllText("$Path.tmp", $Text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move("$Path.tmp", $Path, $true)
}
function Get-CleanupConfigDigest {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}
function Assert-CleanupReloadEnvironment {
    param($Configuration,[string]$Root)
    Assert-CleanupLocalPath $Root
    foreach ($path in @($Configuration.Paths.State,$Configuration.Paths.Logs,$Configuration.Audit.CopyDirectory)) {
        if (-not $path) { continue }
        Assert-CleanupLocalPath $path
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if (-not $full.StartsWith("$Root\",[StringComparison]::OrdinalIgnoreCase)) { throw 'Pastas de dados devem permanecer dentro da instalacao.' }
        foreach ($protected in 'scripts','config','certificates') {
            $base = Join-Path $Root $protected
            if ($full -eq $base -or $full.StartsWith("$base\",[StringComparison]::OrdinalIgnoreCase)) { throw "Pasta de dados protegida: $full" }
        }
    }
    $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$($Configuration.Authentication.CertificateThumbprint)" -ErrorAction Stop
    if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) { throw 'Certificado de maquina ausente, sem chave privada ou fora da validade.' }
    if (-not $Configuration.ContainsKey('PnPModulePath') -or -not $Configuration.PnPModulePath) { throw 'Informe PnPModulePath validado pelo instalador.' }
    $modulePath = [IO.Path]::GetFullPath($Configuration.PnPModulePath)
    $moduleRoot = Join-Path $env:ProgramFiles 'PowerShell\Modules'
    if (-not $modulePath.StartsWith("$moduleRoot\",[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($modulePath) -ne 'PnP.PowerShell.psd1' -or -not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw 'Manifesto PnP compartilhado nao encontrado ou fora de Program Files.' }
    $metadata = Import-PowerShellDataFile -LiteralPath $modulePath -ErrorAction Stop
    $version = [version]$metadata.ModuleVersion
    if ($version -lt [version]'3.4.1' -or $version.Major -ne 3 -or
        ($metadata.PowerShellVersion -and [version]$metadata.PowerShellVersion -gt $PSVersionTable.PSVersion)) { throw 'Manifesto PnP incompativel: exige serie 3.x a partir de 3.4.1 e PowerShell compativel.' }
}
function Stop-CleanupReloadTask {
    param([string]$Name,[scriptblock]$OnRunning)
    $task = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) { return }
    Disable-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop | Out-Null
    if ($task.State -eq 'Running' -or (Get-ScheduledTask -TaskName $Name -TaskPath '\').State -eq 'Running') {
        if ($OnRunning) { & $OnRunning }
        Stop-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-ScheduledTask -TaskName $Name -TaskPath '\').State -eq 'Running') {
        if ($timer.Elapsed.TotalSeconds -ge 30) { throw "Tarefa '$Name' nao parou em 30 segundos." }
        Start-Sleep -Milliseconds 250
    }
}
function Restore-CleanupReload {
    param($Recovery,[string]$ActivePath,[string]$JournalPath)
    foreach ($name in @($Recovery.TargetNames + @($Recovery.Tasks | ForEach-Object Name) | Select-Object -Unique)) { Stop-CleanupReloadTask $name }
    foreach ($name in $Recovery.TargetNames) {
        if ($name -notin @($Recovery.Tasks | ForEach-Object Name)) {
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Set-CleanupActiveConfiguration -Path $ActivePath -Text $Recovery.ActiveText
    foreach ($task in $Recovery.Tasks) {
        Register-ScheduledTask -TaskName $task.Name -TaskPath '\' -Xml $task.Xml -Force -ErrorAction Stop | Out-Null
    }
    foreach ($task in $Recovery.Tasks) { if ($task.WasRunning) { Start-ScheduledTask -TaskName $task.Name -TaskPath '\' -ErrorAction Stop } }
    Remove-Item -LiteralPath $JournalPath -Force -ErrorAction Stop
}
function Register-CleanupReloadTask {
    param([string]$ConfigPath)
    $root = Split-Path (Split-Path $ConfigPath -Parent) -Parent
    $name = 'SharePoint Version Cleanup - Config Reload'
    $existing = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing) {
        if (@($existing.Actions).Count -ne 1 -or -not $existing.Actions[0].Arguments.Contains("`"$ConfigPath`"")) { throw 'Monitor de recarga pertence a outra instalacao.' }
        if (-not $script:TaskBackups.ContainsKey($name)) { $script:TaskBackups[$name] = Export-ScheduledTask -TaskName $name -TaskPath '\' }
    } else { $script:NewTasks.Add($name) }
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $root 'scripts/Reload-Configuration.ps1')`" -ConfigPath `"$ConfigPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Recarrega configuracao valida e reinicia tarefas em execucao.' -Force -ErrorAction Stop | Out-Null
}
function Invoke-CleanupConfigurationReload {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $ErrorActionPreference = 'Stop'
    $source = [IO.Path]::GetFullPath($ConfigPath)
    $root = Split-Path (Split-Path $source -Parent) -Parent
    if ($source -ne (Join-Path $root 'config\config.json')) { throw 'Use config/config.json da instalacao.' }
    if (-not $PSCmdlet.ShouldProcess($source,'Recarregar configuracao e reiniciar tarefas ativas')) { return }
    $lock = $null
    $activePath = Join-Path $root 'config/active-config.json'
    $journalPath = Join-Path $root '.reload-recovery.json'
    $recovery = $null; $stage = 'ler configuracao'; $mutating = $false
    try {
        Assert-CleanupLocalPath $root
        try { $lock = [IO.File]::Open((Join-Path $root '.install.lock'),'OpenOrCreate','ReadWrite','None') }
        catch [IO.IOException] { return } # Installation or another reload owns the app.
        if (Test-Path -LiteralPath (Join-Path $root '.install-recovery.json')) { throw 'Instalacao com recuperacao pendente; consulte .install-recovery.json.' }
        if (Test-Path -LiteralPath $journalPath) {
            $stage = 'recuperar recarga anterior'; $mutating = $true
            $recovery = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable
            Restore-CleanupReload -Recovery $recovery -ActivePath $activePath -JournalPath $journalPath
            Write-CleanupReloadLog $root 'Recarga anterior interrompida; configuracao e tarefas anteriores restauradas.'
            $recovery = $null; $mutating = $false
        }
        $text = [IO.File]::ReadAllText($source)
        $activeText = [IO.File]::ReadAllText($activePath)
        if ((Get-CleanupConfigDigest $text) -eq (Get-CleanupConfigDigest $activeText)) { return }
        Start-Sleep -Seconds 2
        if ($text -cne [IO.File]::ReadAllText($source)) { throw 'Arquivo ainda em gravacao; sera conferido novamente no proximo ciclo.' }
        $stage = 'validar JSON'
        $new = Read-CleanupConfiguration -Values ($text | ConvertFrom-Json -AsHashtable)
        $old = Read-CleanupConfiguration -Values ($activeText | ConvertFrom-Json -AsHashtable)
        Assert-CleanupReloadEnvironment -Configuration $new -Root $root
        $owned = @(Get-ScheduledTask -TaskPath '\' | Where-Object {
            $_.TaskName -match '^SharePoint Version Cleanup - \d+$' -and @($_.Actions | Where-Object { $_.Arguments -and $_.Arguments.Contains("`"$source`"") }).Count
        })
        $targetNames = @(for ($i=0; $i -lt $new.Sites.Count; $i++) { 'SharePoint Version Cleanup - {0:D2}' -f ($i+1) })
        foreach ($name in $targetNames) {
            $existing = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
            if ($existing -and $name -notin @($owned.TaskName)) { throw "Tarefa '$name' pertence a outra configuracao." }
        }
        $production = @(); $restartSites = @(); $disabledSites = @(); $snapshots = @()
        foreach ($task in $owned) {
            if (@($task.Actions).Count -ne 1 -or $task.Principal.LogonType -eq 'Password') { throw "Tarefa '$($task.TaskName)' nao pode ser atualizada automaticamente." }
            $index = [int](($task.TaskName -split ' - ')[-1]) - 1
            if ($index -ge 0 -and $index -lt $old.Sites.Count) {
                $site = $old.Sites[$index]
                if (-not $task.Actions[0].Arguments.Contains("-SiteUrl `"$site`"")) { throw "Site da tarefa '$($task.TaskName)' difere da configuracao ativa." }
                if ($task.State -eq 'Running' -and $site -in $new.Sites) { $restartSites += $site }
                if ($task.State -eq 'Disabled') { $disabledSites += $site }
                if ($task.Actions[0].Arguments -match '(?:^|\s)-Apply(?:\s|$)' -and $site -in $new.Sites -and
                    $old.FolderScopes[$site] -eq $new.FolderScopes[$site] -and $old.VersionsToKeep -eq $new.VersionsToKeep -and
                    $old.Safety.MinimumVersionAgeDays -eq $new.Safety.MinimumVersionAgeDays -and $old.Tenant -eq $new.Tenant -and
                    $old.Authentication.ClientId -eq $new.Authentication.ClientId -and $old.Authentication.CertificateThumbprint -eq $new.Authentication.CertificateThumbprint) { $production += $site }
            }
            $snapshots += @{Name=$task.TaskName;Xml=(Export-ScheduledTask -TaskName $task.TaskName -TaskPath '\');WasRunning=($task.State -eq 'Running')}
        }
        $recovery = @{ActiveText=$activeText;Tasks=$snapshots;TargetNames=$targetNames}
        $recovery | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$journalPath.tmp" -Encoding utf8
        [IO.File]::Move("$journalPath.tmp",$journalPath,$true)
        Write-CleanupReloadLog $root 'JSON valido alterado; parando tarefas e aplicando configuracao completa.'
        $mutating = $true; $stage = 'parar tarefas'
        foreach ($task in $owned) {
            $snapshot = $recovery.Tasks | Where-Object Name -EQ $task.TaskName | Select-Object -First 1
            $onRunning = {
                $snapshot.WasRunning = $true
                $recovery | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$journalPath.tmp" -Encoding utf8
                [IO.File]::Move("$journalPath.tmp",$journalPath,$true)
            }.GetNewClosure()
            Stop-CleanupReloadTask -Name $task.TaskName -OnRunning $onRunning
        }
        $restartSites = @($recovery.Tasks | Where-Object WasRunning | ForEach-Object {
            $index = [int](($_.Name -split ' - ')[-1])-1
            if ($index -ge 0 -and $index -lt $old.Sites.Count -and $old.Sites[$index] -in $new.Sites) { $old.Sites[$index] }
        })
        $stage = 'preparar certificado e pastas'
        $null = Install-CleanupServiceCertificate -Thumbprint $new.Authentication.CertificateThumbprint
        foreach ($path in @($new.Paths.State,$new.Paths.Logs,$new.Audit.CopyDirectory)) {
            if (-not $path) { continue }
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-CleanupServiceAcl -Path $path -ServiceRights Modify
        }
        if ($text -cne [IO.File]::ReadAllText($source)) { throw 'JSON mudou durante a recarga; sera tentado novamente.' }
        $stage = 'atualizar tarefas'
        $script:TaskPrefix = 'SharePoint Version Cleanup'
        $script:TaskBackups = @{}; $script:NewTasks = [Collections.Generic.List[string]]::new()
        Set-CleanupActiveConfiguration -Path $activePath -Text $text
        Install-ScheduledTasks -Configuration $new -Destination $root -ProductionSites $production -KeepDisabled
        foreach ($task in $owned) {
            if ($task.TaskName -notin $targetNames) { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
        }
        if ($text -cne [IO.File]::ReadAllText($source)) { throw 'JSON mudou durante a atualizacao de tarefas; sera tentado novamente.' }
        $stage = 'reiniciar tarefas'
        for ($i=0; $i -lt $new.Sites.Count; $i++) {
            if ($new.Sites[$i] -notin $disabledSites) { Enable-ScheduledTask -TaskName $targetNames[$i] -TaskPath '\' -ErrorAction Stop | Out-Null }
            if ($new.Sites[$i] -in $restartSites) { Start-ScheduledTask -TaskName $targetNames[$i] -TaskPath '\' -ErrorAction Stop }
        }
        Write-CleanupReloadLog $root "JSON recarregado com sucesso. Tarefas atualizadas: $($targetNames.Count); reiniciadas: $($restartSites.Count). Tarefas inativas aguardam o horario. Producao preservada somente para escopo, identidade e retencao inalterados."
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
        $mutating = $false
    } catch {
        $reason = $_.Exception.Message
        $outcome = 'Configuracao ativa e tarefas anteriores mantidas.'
        if ($mutating -and $recovery) {
            try { Restore-CleanupReload -Recovery $recovery -ActivePath $activePath -JournalPath $journalPath; $outcome = 'Configuracao e tarefas anteriores restauradas.' }
            catch { $outcome = "Recuperacao incompleta: $($_.Exception.Message). Revise $journalPath; o monitor tentara recuperar no proximo ciclo." }
        }
        Write-CleanupReloadLog $root "JSON nao recarregado por erro na etapa '$stage': $reason $outcome"
        throw "[SPVC-CONFIG-RELOAD] JSON nao recarregado: $reason $outcome"
    } finally { if ($lock) { $lock.Dispose() } }
}

if ($MyInvocation.InvocationName -eq '.') { return }
. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot 'TaskIdentity.ps1')
. (Join-Path $PSScriptRoot 'ScheduledTasks.ps1')
Invoke-CleanupConfigurationReload -ConfigPath $ConfigPath -WhatIf:$WhatIfPreference
