#requires -Version 7.4.6
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$SiteUrl,
    [Parameter(Mandatory = $true)][string]$FolderServerRelativeUrl,
    [switch]$Apply,
    [string]$Confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cleanupScript = Join-Path $PSScriptRoot 'cleanup-versions.ps1'
if (-not (Test-Path -LiteralPath $cleanupScript)) { throw "Script ausente: $cleanupScript" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuracao ausente: $ConfigPath" }

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($SiteUrl -notin @($config.Sites)) {
    throw 'O site piloto deve estar explicitamente cadastrado em config.json.'
}

if ($Apply -and $Confirmation -cne 'APLICAR NO SITE PILOTO') {
    throw "Para efetivar o piloto, informe -Confirmation 'APLICAR NO SITE PILOTO'."
}

$arguments = @{ ConfigPath = $ConfigPath; SiteUrl = $SiteUrl; FolderServerRelativeUrl = $FolderServerRelativeUrl; PassThru = $true }
if ($Apply) { $arguments.Apply = $true }
$report = & $cleanupScript @arguments
Write-Host "`nResultado do piloto" -ForegroundColor Cyan
Write-Host "Site: $($report.SiteUrl)"
Write-Host "Modo: $(if ($report.Apply) { 'APLICADO' } else { 'SIMULACAO' })"
Write-Host "Arquivos: $($report.FilesProcessed)"
Write-Host "Versoes elegiveis: $($report.VersionsEligible); removidas: $($report.VersionsDeleted)"
Write-Host "Ignorados: $($report.FilesSkipped)"
Write-Host "Relatorio: $($report.ReportPath)"

if (-not $Apply) {
    Write-Warning "Revise o relatorio e os logs. Para o piloto real, repita com -Apply -Confirmation 'APLICAR NO SITE PILOTO'."
}
