#requires -Version 7.4.6
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Este teste exige Windows e Agendador de Tarefas.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Este teste exige Windows elevado.'
}
. (Join-Path $PSScriptRoot '../scripts/Progress.ps1')
. (Join-Path $PSScriptRoot '../scripts/TaskIdentity.ps1')
$parent = [IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')
$caseName = 'SPVC-ServiceIntegration-' + [guid]::NewGuid().ToString('N')
$caseRoot = Join-Path $parent $caseName
$existingTasks = @(Get-ScheduledTask -TaskName 'SPVC-ServiceTest-*' -ErrorAction SilentlyContinue | ForEach-Object TaskName)
try {
    foreach ($relative in '', 'scripts', 'config', 'state') { $null = New-Item -ItemType Directory -Path (Join-Path $caseRoot $relative) -Force }
    # A disposable worker exercises the real scheduler/account without using
    # certificates, Microsoft 365, network connections, email or production data.
    @'
param([string]$ConfigPath,[string]$ResultPath)
$ErrorActionPreference = 'Stop'
$mode = (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).Mode
if ($mode -eq 'NoResult') { exit 17 }
if ($mode -eq 'StageTimeout') {
    @{Sequence=1;Stage='connect';Detail='https://diagnostic.sharepoint.com'} | ConvertTo-Json | Set-Content -LiteralPath "$ResultPath.progress.json"
    Start-Sleep -Seconds 60; exit 19
}
if ($mode -eq 'Timeout') { Start-Sleep -Seconds 60; exit 18 }
@{Scope='Full';Success=$true;Identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Error=''} |
    ConvertTo-Json | Set-Content -LiteralPath "$ResultPath.tmp" -Encoding utf8
[IO.File]::Move("$ResultPath.tmp",$ResultPath,$true)
'@ | Set-Content -LiteralPath (Join-Path $caseRoot 'scripts/Test-ServiceContext.ps1') -Encoding utf8
    $configPath = Join-Path $caseRoot 'config/config.json'
    '{"Mode":"Success"}' | Set-Content -LiteralPath $configPath -Encoding utf8
    Set-CleanupServiceAcl -Path $caseRoot
    foreach ($entry in Get-ChildItem -LiteralPath $caseRoot -Recurse -Force) { Set-CleanupServiceAcl -Path $entry.FullName }
    $statePath = Join-Path $caseRoot 'state'
    Set-CleanupServiceAcl -Path $statePath -ServiceRights Modify
    $configuration = @{Paths=@{State=$statePath}}
    foreach ($mode in 'Success','NoResult','Timeout','StageTimeout') {
        @{Mode=$mode} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        $timeout = if ($mode -eq 'Timeout') { 3 } else { 45 }
        $stageTimeout = if ($mode -eq 'StageTimeout') { 15 } else { 45 }
        $expected = switch ($mode) {
            StageTimeout { '*Tempo limite*etapa*connect*https://diagnostic.sharepoint.com*' }
            NoResult { '*SPVC-SERVICE*terminou sem gravar*0x00000011*Executavel:*pwsh.exe*' }
            Timeout { '*SPVC-SERVICE*Tempo limite*Executavel:*pwsh.exe*' }
            default { $null }
        }
        $failure = $null
        try { Test-CleanupServiceExecution -Configuration $configuration -Destination $caseRoot -TimeoutSeconds $timeout -StageTimeoutSeconds $stageTimeout }
        catch { $failure = $_.Exception.Message }
        if ($expected -and ($null -eq $failure -or $failure -notlike $expected)) { throw "Diagnostico inesperado para ${mode}: $failure" }
        if (-not $expected -and $failure) { throw $failure }
        if (@(Get-ChildItem -LiteralPath $statePath -Force).Count) { throw 'O resultado temporario nao foi removido.' }
        $leftoverTasks = @(Get-ScheduledTask -TaskName 'SPVC-ServiceTest-*' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -notin $existingTasks })
        if ($leftoverTasks.Count) { throw 'Tarefa temporaria nao removida apos o teste.' }
        Write-Host "PASS: Agendador real, LOCAL SERVICE, cenario $mode e limpeza de tarefa/resultado."
    }
} finally {
    if (Test-Path -LiteralPath $caseRoot) {
        $resolved = (Resolve-Path -LiteralPath $caseRoot).Path
        if ((Split-Path $resolved -Parent) -ne $parent -or (Split-Path $resolved -Leaf) -ne $caseName -or
            (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Destino de limpeza do teste invalido.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}
