#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$PilotSiteUrl,
    [Parameter(Mandatory)][string[]]$TaskName,
    [string]$PilotFolderServerRelativeUrl = '',
    [Parameter(Mandatory)][ValidateSet('ATIVAR PRODUCAO')][string]$Confirmation,
    [ValidateRange(1,30)][int]$MaximumPilotAgeDays = 7
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Configuration.ps1')
$config = Read-CleanupConfiguration $ConfigPath
$PilotSiteUrl = ConvertTo-SiteUrl $PilotSiteUrl
if ($PilotSiteUrl -notin $config.Sites) { throw 'Site piloto nao cadastrado.' }
$now = (Get-Date).ToUniversalTime()
$pilot = Get-ChildItem -LiteralPath $config.Paths.Logs -Filter 'report-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
        try {
            $r = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($r.SiteUrl -eq $PilotSiteUrl -and $r.Success -eq $true -and $r.Apply -eq $true -and
                $r.VersionsToKeep -eq $config.VersionsToKeep -and $r.FilesProcessed -gt 0 -and
                $r.VersionsDeleted -gt 0 -and $r.FilesSkipped -eq 0 -and
                $r.FolderServerRelativeUrl -eq $PilotFolderServerRelativeUrl.TrimEnd('/') -and
                ([datetime]$r.FinishedAt).ToUniversalTime() -ge $now.AddDays(-$MaximumPilotAgeDays) -and
                ([datetime]$r.FinishedAt).ToUniversalTime() -le $now) { $r }
        } catch { Write-Verbose "Relatorio invalido ignorado: $($_.Exception.Message)" }
    } | Select-Object -First 1
if (-not $pilot) { throw 'Nenhum piloto aplicado recente com exclusoes e sem falhas no mesmo site, pasta e retencao.' }
# Validate every target before changing any task. Never promote other sites by prefix.
$updates = foreach ($name in ($TaskName | Select-Object -Unique)) {
    if ($name -notmatch '^SharePoint Version Cleanup - \d+$') { throw "Nome de tarefa invalido: $name" }
    $task = Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop
    if (@($task.Actions).Count -ne 1) { throw "Acoes inesperadas: $name" }
    $action = $task.Actions[0]
    $base = Split-Path (Split-Path ([IO.Path]::GetFullPath($ConfigPath)) -Parent) -Parent
    $cleanup = Join-Path $base 'scripts\cleanup-versions.ps1'
    $expected = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cleanup`" -ConfigPath `"$([IO.Path]::GetFullPath($ConfigPath))`" -SiteUrl `"$PilotSiteUrl`""
    if ($PilotFolderServerRelativeUrl) { $expected += " -FolderServerRelativeUrl `"$($PilotFolderServerRelativeUrl.TrimEnd('/'))`"" }
    if ([IO.Path]::GetFileName($action.Execute) -ne 'pwsh.exe' -or
        ($action.Arguments -ne $expected -and $action.Arguments -ne "$expected -Apply")) {
        throw "A tarefa '$name' nao corresponde exatamente ao escopo validado no piloto."
    }
    @{ Task = $task; Execute = $action.Execute; Arguments = "$expected -Apply" }
}
$count = 0
foreach ($update in $updates) {
    if ($PSCmdlet.ShouldProcess($update.Task.TaskName, 'Habilitar exclusao no escopo validado')) {
        $action = New-ScheduledTaskAction -Execute $update.Execute -Argument $update.Arguments
        Set-ScheduledTask -TaskName $update.Task.TaskName -TaskPath '\' -Action $action | Out-Null
        $count++
    }
}
Write-Host "$count tarefa(s) promovida(s)."
