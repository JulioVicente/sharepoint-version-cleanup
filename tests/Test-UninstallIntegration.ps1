#requires -Version 7.4.6
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/Uninstall.ps1')
Assert-UninstallAdministrator
# No real scheduler or tenant calls: exercise only native file moves and Windows ACLs.
function Get-ScheduledTask { param($TaskPath,$TaskName) @() }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$caseRoot = Join-Path $temporaryRoot ('spvc-uninstall-test-' + [guid]::NewGuid().ToString('N'))
$installation = Join-Path $caseRoot 'install'
try {
    foreach ($relative in 'scripts','config','state','logs') { $null = New-Item -ItemType Directory -Path (Join-Path $installation $relative) -Force }
    '{"Algorithm":"SHA256","Files":{"scripts/cleanup-versions.ps1":"fixture"}}' | Set-Content (Join-Path $installation 'release-manifest.json')
    'fixture' | Set-Content (Join-Path $installation 'scripts/cleanup-versions.ps1')
    'config-fixture' | Set-Content (Join-Path $installation 'config/config.json')
    'state-fixture' | Set-Content (Join-Path $installation 'state/checkpoint.json')
    'audit-fixture' | Set-Content (Join-Path $installation 'logs/report.json')
    Invoke-CleanupUninstall -InstallPath $installation -Force
    $backup = @(Get-ChildItem -LiteralPath $caseRoot -Directory | Where-Object Name -Like 'install-uninstalled-*')
    if ($backup.Count -ne 1) { throw 'Backup ausente ou ambiguo.' }
    if (Test-Path (Join-Path $installation 'config/config.json')) { throw 'Configuracao antiga permaneceu ativa.' }
    if ((Get-Content (Join-Path $backup[0].FullName 'state/checkpoint.json')) -ne 'state-fixture') { throw 'Estado nao preservado.' }
    if ((Get-Content (Join-Path $installation 'logs/report.json')) -ne 'audit-fixture') { throw 'Auditoria nao preservada.' }
    foreach ($item in @($backup[0]) + @(Get-ChildItem -LiteralPath $backup[0].FullName -Recurse -Force)) {
        $acl = Get-Acl -LiteralPath $item.FullName
        if (-not $acl.AreAccessRulesProtected) { throw "ACL nao protegida: $($item.Name)" }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne 2 -or @($rules | Where-Object { $_.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' }).Count) {
            throw "ACL inesperada no backup: $($item.Name)"
        }
    }
    $record = Get-Content (Join-Path $backup[0].FullName 'uninstall-summary.json') -Raw | ConvertFrom-Json
    if ($record.Status -ne 'Completed') { throw 'Desinstalacao incompleta.' }
    Write-Host 'OK: arquivos arquivados, auditoria preservada e ACLs reais limitadas a administradores e SYSTEM.'
} finally {
    if (Test-Path -LiteralPath $caseRoot) {
        $resolved = (Resolve-Path -LiteralPath $caseRoot).Path
        if ((Split-Path $resolved -Parent) -ne $temporaryRoot -or (Split-Path $resolved -Leaf) -notlike 'spvc-uninstall-test-*' -or
            (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Destino de limpeza do teste invalido.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}
