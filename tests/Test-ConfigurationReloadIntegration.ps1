#requires -Version 7.4.6
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ModulePath)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'scripts/Configuration.ps1')
. (Join-Path $project 'scripts/TaskIdentity.ps1')
. (Join-Path $project 'scripts/ScheduledTasks.ps1')
. (Join-Path $project 'scripts/Reload-Configuration.ps1') -WhatIf
$names = @('SharePoint Version Cleanup - 01','SharePoint Version Cleanup - Config Reload')
foreach ($name in $names) {
    if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) { throw "Teste recusado: tarefa preexistente $name" }
}
$root = Join-Path $env:ProgramData ('SPVC-ReloadIntegration-' + [guid]::NewGuid().ToString('N'))
$cert = $null
function Wait-Fixture {
    param([scriptblock]$Condition,[string]$Message)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 90) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 500
    }
    $log = Join-Path $root 'config-reload.log'
    if (Test-Path $log) { Get-Content $log -Tail 12 | Write-Host }
    throw "Timeout: $Message"
}
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts'),(Join-Path $root 'config'),(Join-Path $root 'logs'),(Join-Path $root 'state') -Force | Out-Null
    foreach ($file in 'Configuration.ps1','Formatting.ps1','Diagnostics.ps1','Progress.ps1','TaskIdentity.ps1','ScheduledTasks.ps1','Reload-Configuration.ps1') {
        Copy-Item (Join-Path $project "scripts/$file") (Join-Path $root "scripts/$file")
    }
    @'
param($ConfigPath,$SiteUrl,[switch]$UseActiveConfiguration,[switch]$Apply)
$ErrorActionPreference='Stop'
if (-not $UseActiveConfiguration -or $Apply) { throw 'Fixture exige copia ativa em simulacao.' }
$cfg=Get-Content (Join-Path (Split-Path $ConfigPath) 'active-config.json') -Raw | ConvertFrom-Json
@{ProcessId=$PID;Keep=$cfg.VersionsToKeep;Site=$SiteUrl} | ConvertTo-Json | Set-Content (Join-Path $cfg.Paths.Logs 'fixture.json')
Start-Sleep -Seconds 300
'@ | Set-Content (Join-Path $root 'scripts/cleanup-versions.ps1')
    $cert = New-SelfSignedCertificate -Subject 'CN=SPVC Reload Integration disposable' -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddDays(1)
    $cfg = Get-Content (Join-Path $project 'config/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $cfg.Sites=@('https://contoso.sharepoint.com'); $cfg.FolderScopes=@{}
    $cfg.Authentication.CertificateThumbprint=$cert.Thumbprint
    $cfg.Email.Enabled=$false; $cfg.Audit.CopyDirectory=''
    $cfg.Paths=@{Logs=(Join-Path $root 'logs');State=(Join-Path $root 'state')}
    $cfg.PnPModulePath=$ModulePath
    $cfg.Schedule=@{Frequency='diaria';Time=(Get-Date).AddHours(2).ToString('HH:mm')}
    $source=Join-Path $root 'config/config.json'; $active=Join-Path $root 'config/active-config.json'
    $cfg | ConvertTo-Json -Depth 8 | Set-Content $source
    Copy-Item $source $active
    Initialize-CleanupServiceIdentity -Configuration $cfg -Destination $root
    $script:TaskPrefix='SharePoint Version Cleanup'; $script:TaskBackups=@{}; $script:NewTasks=[Collections.Generic.List[string]]::new()
    Install-ScheduledTasks -Configuration $cfg -Destination $root
    Register-CleanupReloadTask -ConfigPath $source
    Start-ScheduledTask -TaskName $names[0] -TaskPath '\'
    $marker=Join-Path $root 'logs/fixture.json'
    Wait-Fixture { Test-Path $marker } 'worker inicial'
    $first=Get-Content $marker -Raw | ConvertFrom-Json
    $cfg.VersionsToKeep=3; $cfg.Schedule.Time=(Get-Date).AddHours(3).ToString('HH:mm')
    $cfg | ConvertTo-Json -Depth 8 | Set-Content $source
    Start-ScheduledTask -TaskName $names[1] -TaskPath '\'
    Wait-Fixture {
        try { $result=Get-Content $marker -Raw | ConvertFrom-Json; $result.ProcessId -ne $first.ProcessId -and $result.Keep -eq 3 } catch { $false }
    } 'restart apos JSON valido'
    Wait-Fixture { (Get-ScheduledTask -TaskName $names[1]).State -ne 'Running' } 'monitor concluir'
    $second=Get-Content $marker -Raw | ConvertFrom-Json
    $trigger=(Get-ScheduledTask -TaskName $names[0]).Triggers[0]
    if (([datetime]$trigger.StartBoundary).ToString('HH:mm') -ne $cfg.Schedule.Time) { throw 'Horario nao foi sincronizado.' }
    $accepted=(Get-FileHash $active).Hash
    '{invalid' | Set-Content $source
    Start-ScheduledTask -TaskName $names[1] -TaskPath '\'
    Wait-Fixture { (Test-Path (Join-Path $root 'config-reload.log')) -and (Get-Content (Join-Path $root 'config-reload.log') -Raw) -match 'JSON nao recarregado por erro' } 'diagnostico de JSON invalido'
    Wait-Fixture { (Get-ScheduledTask -TaskName $names[1]).State -ne 'Running' } 'monitor rejeitar JSON'
    if ((Get-FileHash $active).Hash -ne $accepted) { throw 'JSON invalido substituiu a copia ativa.' }
    if ((Get-Content $marker -Raw | ConvertFrom-Json).ProcessId -ne $second.ProcessId -or (Get-ScheduledTask -TaskName $names[0]).State -ne 'Running') { throw 'JSON invalido interrompeu o worker.' }
    'PASS: monitor SYSTEM real, restart LOCAL SERVICE, novo JSON e horario aplicados; JSON invalido preservou execucao e registrou motivo.'
} finally {
    foreach ($name in $names) {
        if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    if ($cert) { Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($root)
    $base=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
    if (-not $resolved.StartsWith("$base\SPVC-ReloadIntegration-",[StringComparison]::OrdinalIgnoreCase)) { throw 'Raiz inesperada; limpeza recusada.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

