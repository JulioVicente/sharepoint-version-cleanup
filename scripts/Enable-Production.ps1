#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$PilotSiteUrl,
    [Parameter(Mandatory = $true)][ValidateSet('ATIVAR PRODUCAO')][string]$Confirmation,
    [int]$MaximumPilotAgeDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskPrefix = 'SharePoint Version Cleanup'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$pilot = Get-ChildItem -LiteralPath $config.Paths.Logs -Filter 'report-*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    ForEach-Object {
        try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { $null }
    } |
    Where-Object {
        $_ -and $_.SiteUrl -eq $PilotSiteUrl -and $_.Success -and $_.Apply -and
        ([datetime]$_.FinishedAt).ToUniversalTime() -ge (Get-Date).ToUniversalTime().AddDays(-$MaximumPilotAgeDays)
    } |
    Select-Object -First 1

if (-not $pilot) {
    throw "Nenhum piloto aplicado com sucesso para $PilotSiteUrl nos ultimos $MaximumPilotAgeDays dias."
}

$tasks = @(Get-ScheduledTask -TaskName "$taskPrefix - *" -ErrorAction SilentlyContinue)
if ($tasks.Count -eq 0) { throw "Nenhuma tarefa com prefixo '$taskPrefix' foi encontrada." }

foreach ($task in $tasks) {
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) { throw "A tarefa '$($task.TaskName)' possui uma configuracao de acoes inesperada." }
    $action = $actions[0]
    $arguments = [string]$action.Arguments
    if ($arguments -notmatch '(?i)(^|\s)-Apply(\s|$)') { $arguments = "$arguments -Apply" }
    $newAction = New-ScheduledTaskAction -Execute $action.Execute -Argument $arguments -WorkingDirectory $action.WorkingDirectory
    if ($PSCmdlet.ShouldProcess($task.TaskName, 'Habilitar exclusao de versoes em producao')) {
        Set-ScheduledTask -TaskName $task.TaskName -Action $newAction | Out-Null
    }
}

Write-Host "$($tasks.Count) tarefa(s) promovida(s) para producao." -ForegroundColor Green

